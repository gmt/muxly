import errno
import json
import os
import pathlib
import pty
import select
import subprocess
import tempfile
import time


REPO = pathlib.Path(__file__).resolve().parents[2]
SOCKET_PATH = "/tmp/muxly-integration.sock"
SESSION_NAME = "muxly-integration-demo"
NESTED_SESSION_NAME = "muxly-integration-nested-demo"
DRIFT_SESSION_NAME = "muxly-integration-drift-demo"
FREEZE_SESSION_NAME = "muxly-integration-freeze-demo"
FREEZE_SURFACE_SESSION_NAME = "muxly-integration-freeze-surface-demo"
LIVE_VIEWER_SESSION_NAME = "muxly-integration-live-viewer-demo"


def run_cli(env: dict[str, str], *args: str) -> dict:
    output = subprocess.check_output(
        [str(REPO / "zig-out/bin/muxly"), *args],
        cwd=REPO,
        env=env,
        text=True,
    )
    return json.loads(output)


def wait_for_socket(path: str, timeout: float = 5.0) -> None:
    deadline = time.time() + timeout
    while time.time() < deadline:
        if os.path.exists(path):
            return
        time.sleep(0.05)
    raise RuntimeError(f"socket did not appear: {path}")


def cleanup_tmux_session(env: dict[str, str], session_name: str) -> None:
    subprocess.run(
        ["tmux", "kill-session", "-t", session_name],
        cwd=REPO,
        env=env,
        check=False,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
    )


def wait_for_pane_content(env: dict[str, str], pane_id: str, needle: str, timeout: float = 3.0) -> dict:
    deadline = time.time() + timeout
    last_capture: dict | None = None
    while time.time() < deadline:
        last_capture = run_cli(env, "pane", "capture", pane_id)
        if needle in last_capture["result"]["content"]:
            return last_capture
        time.sleep(0.1)
    raise AssertionError(
        f"timed out waiting for pane {pane_id} to contain {needle!r}: {last_capture!r}"
    )


def wait_for_node_absent(env: dict[str, str], node_id: int, timeout: float = 3.0) -> dict:
    deadline = time.time() + timeout
    last_document: dict | None = None
    while time.time() < deadline:
        last_document = run_cli(env, "document", "get")
        node_ids = {node["id"] for node in last_document["result"]["nodes"]}
        if node_id not in node_ids:
            return last_document
        time.sleep(0.1)
    raise AssertionError(f"timed out waiting for node {node_id} to disappear: {last_document!r}")


def wait_for_pane_node(env: dict[str, str], pane_id: str, timeout: float = 3.0) -> tuple[dict, dict]:
    deadline = time.time() + timeout
    last_document: dict | None = None
    while time.time() < deadline:
        last_document = run_cli(env, "document", "get")
        document = last_document["result"]
        matches = [
            node
            for node in document["nodes"]
            if node["kind"] == "tty_leaf" and node["source"].get("paneId") == pane_id
        ]
        if matches:
            return last_document, matches[0]
        time.sleep(0.1)
    raise AssertionError(f"timed out waiting for pane node {pane_id!r}: {last_document!r}")


def wait_for_window_name(env: dict[str, str], window_id: str, expected_name: str, timeout: float = 3.0) -> dict:
    deadline = time.time() + timeout
    last_windows: dict | None = None
    while time.time() < deadline:
        last_windows = run_cli(env, "window", "list")
        matches = [item for item in last_windows["result"] if item["windowId"] == window_id]
        if matches and matches[0]["windowName"] == expected_name:
            return last_windows
        time.sleep(0.1)
    raise AssertionError(
        f"timed out waiting for window {window_id} to be named {expected_name!r}: {last_windows!r}"
    )


def wait_for_node_content(env: dict[str, str], node_id: int, needle: str, timeout: float = 3.0) -> dict:
    deadline = time.time() + timeout
    last_node: dict | None = None
    while time.time() < deadline:
        last_node = run_cli(env, "node", "get", str(node_id))
        if needle in last_node["result"]["content"]:
            return last_node
        time.sleep(0.1)
    raise AssertionError(f"timed out waiting for node {node_id} to contain {needle!r}: {last_node!r}")


def wait_for_pty_output(fd: int, needle: bytes, timeout: float = 5.0) -> bytes:
    deadline = time.time() + timeout
    buffer = bytearray()

    while time.time() < deadline:
        ready, _, _ = select.select([fd], [], [], 0.1)
        if not ready:
            continue
        try:
            chunk = os.read(fd, 65536)
        except OSError as exc:
            if exc.errno == errno.EIO:
                break
            raise
        if not chunk:
            break
        buffer.extend(chunk)
        if needle in buffer:
            return bytes(buffer)

    raise AssertionError(f"timed out waiting for PTY output {needle!r}: {bytes(buffer)!r}")


def main() -> None:
    env = os.environ.copy()
    env["MUXLY_SOCKET"] = SOCKET_PATH

    try:
        os.remove(SOCKET_PATH)
    except FileNotFoundError:
        pass

    cleanup_tmux_session(env, SESSION_NAME)
    cleanup_tmux_session(env, NESTED_SESSION_NAME)
    cleanup_tmux_session(env, DRIFT_SESSION_NAME)
    cleanup_tmux_session(env, FREEZE_SESSION_NAME)
    cleanup_tmux_session(env, FREEZE_SURFACE_SESSION_NAME)
    cleanup_tmux_session(env, LIVE_VIEWER_SESSION_NAME)

    daemon = subprocess.Popen(
        [str(REPO / "zig-out/bin/muxlyd")],
        cwd=REPO,
        env=env,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.PIPE,
        text=True,
    )

    try:
        wait_for_socket(SOCKET_PATH)

        ping = run_cli(env, "ping")
        assert ping["result"]["pong"] is True

        capabilities = run_cli(env, "capabilities", "get")["result"]
        assert capabilities["followTailSemantics"] == "stored-node-preference"
        assert capabilities["viewStateScope"] == "shared-document"
        assert capabilities["tmuxBackendMode"] == "hybrid-control-invalidation"
        assert capabilities["supportsUnixSocket"] is True
        assert capabilities["supportsNamedPipes"] is False
        assert capabilities["implementedTransports"] == ["unix-domain-socket"]

        appended = run_cli(env, "node", "append", "1", "subdocument", "notes")
        assert appended["result"]["nodeId"] > 0
        node_id = appended["result"]["nodeId"]
        updated = run_cli(env, "node", "update", str(node_id), "content", "hello document")
        assert updated["result"]["ok"] is True
        node = run_cli(env, "node", "get", str(node_id))
        assert node["result"]["content"] == "hello document"

        root = run_cli(env, "view", "set-root", str(node_id))
        assert root["result"]["ok"] is True
        clear_root = run_cli(env, "view", "clear-root")
        assert clear_root["result"]["ok"] is True
        elide = run_cli(env, "view", "elide", str(node_id))
        assert elide["result"]["ok"] is True
        expand = run_cli(env, "view", "expand", str(node_id))
        assert expand["result"]["ok"] is True
        removed = run_cli(env, "node", "remove", str(node_id))
        assert removed["result"]["ok"] is True

        with tempfile.TemporaryDirectory() as temp_dir:
            static_path = pathlib.Path(temp_dir) / "static.txt"
            static_path.write_text("alpha\nbeta\n")
            monitored_path = pathlib.Path(temp_dir) / "monitored.txt"
            monitored_path.write_text("line-1\n")

            static_attach = run_cli(env, "leaf", "attach-file", "static-file", str(static_path))
            monitored_attach = run_cli(env, "leaf", "attach-file", "monitored-file", str(monitored_path))
            assert static_attach["result"]["nodeId"] > 0
            assert monitored_attach["result"]["nodeId"] > 0

            static_source = run_cli(env, "leaf", "source-get", str(static_attach["result"]["nodeId"]))
            monitored_source = run_cli(env, "leaf", "source-get", str(monitored_attach["result"]["nodeId"]))
            assert static_source["result"]["source"]["path"] == str(static_path)
            assert static_source["result"]["source"]["mode"] == "static"
            assert monitored_source["result"]["source"]["path"] == str(monitored_path)
            assert monitored_source["result"]["source"]["mode"] == "monitored"

            static_capture = run_cli(env, "file", "capture", str(static_attach["result"]["nodeId"]))
            assert "alpha" in static_capture["result"]["content"]

            monitored_follow = run_cli(env, "file", "follow-tail", str(monitored_attach["result"]["nodeId"]), "false")
            assert monitored_follow["result"]["ok"] is True

            monitored_path.write_text("line-1\nline-2\n")
            document = run_cli(env, "document", "get")["result"]
            nodes = {node["id"]: node for node in document["nodes"]}
            monitored_node = nodes[monitored_attach["result"]["nodeId"]]
            assert "line-2" in monitored_node["content"]
            assert monitored_node["followTail"] is False

            synthetic_parent = run_cli(env, "node", "append", "1", "subdocument", "mixed-notes")
            synthetic_parent_id = synthetic_parent["result"]["nodeId"]
            synthetic_child = run_cli(env, "node", "append", str(synthetic_parent_id), "scroll_region", "child-note")
            synthetic_child_id = synthetic_child["result"]["nodeId"]
            updated_child = run_cli(env, "node", "update", str(synthetic_child_id), "content", "notes beside live sources")
            assert updated_child["result"]["ok"] is True
            remove_parent = run_cli(env, "node", "remove", str(synthetic_parent_id))
            assert remove_parent["error"]["message"].endswith("NodeHasChildren")
            remove_child = run_cli(env, "node", "remove", str(synthetic_child_id))
            assert remove_child["result"]["ok"] is True
            remove_parent = run_cli(env, "node", "remove", str(synthetic_parent_id))
            assert remove_parent["result"]["ok"] is True

        session = run_cli(
            env,
            "session",
            "create",
            SESSION_NAME,
            "sh -lc 'printf \"%s\\\\n\" integration-tmux; sleep 30'",
        )
        assert session["result"]["nodeId"] > 0

        sessions = run_cli(env, "session", "list")
        session_entry = next(item for item in sessions["result"] if item["sessionName"] == SESSION_NAME)
        assert session_entry["sessionId"].startswith("$")

        document = run_cli(env, "document", "get")["result"]
        tty_nodes = [node for node in document["nodes"] if node["kind"] == "tty_leaf"]
        assert tty_nodes, document
        pane_id = tty_nodes[-1]["source"]["paneId"]
        windows = run_cli(env, "window", "list")
        panes = run_cli(env, "pane", "list")
        window_entry = next(item for item in windows["result"] if item["sessionName"] == SESSION_NAME)
        pane_entry = next(item for item in panes["result"] if item["paneId"] == pane_id)
        assert window_entry["sessionId"] == session_entry["sessionId"]
        assert window_entry["windowId"].startswith("@")
        assert "windowName" in window_entry
        assert pane_entry["sessionId"] == session_entry["sessionId"]
        assert pane_entry["windowId"] == window_entry["windowId"]
        assert "paneTitle" in pane_entry
        assert isinstance(pane_entry["paneActive"], bool)
        node = run_cli(env, "node", "get", str(session["result"]["nodeId"]))
        assert node["result"]["id"] == session["result"]["nodeId"]
        assert windows["result"]

        capture = wait_for_pane_content(env, pane_id, "integration-tmux")
        assert "integration-tmux" in capture["result"]["content"]

        external_split_pane_id = subprocess.check_output(
            [
                "tmux",
                "split-window",
                "-d",
                "-P",
                "-F",
                "#{pane_id}",
                "-t",
                pane_id,
                "-h",
                "sh -lc 'printf \"%s\\\\n\" external-split-event; sleep 30'",
            ],
            cwd=REPO,
            env=env,
            text=True,
        ).strip()
        external_panes = run_cli(env, "pane", "list")["result"]
        external_pane_entry = next(item for item in external_panes if item["paneId"] == external_split_pane_id)
        assert external_pane_entry["sessionId"] == session_entry["sessionId"]
        document, external_tty_node = wait_for_pane_node(env, external_split_pane_id)
        external_split_capture = wait_for_pane_content(env, external_split_pane_id, "external-split-event")
        assert "external-split-event" in external_split_capture["result"]["content"]
        subprocess.run(
            ["tmux", "rename-window", "-t", window_entry["windowId"], "externally-renamed"],
            cwd=REPO,
            env=env,
            check=True,
        )
        wait_for_window_name(env, window_entry["windowId"], "externally-renamed")
        external_split_close = run_cli(env, "pane", "close", external_split_pane_id)
        assert external_split_close["result"]["ok"] is True
        document = wait_for_node_absent(env, external_tty_node["id"])["result"]
        node_ids = {node["id"] for node in document["nodes"]}
        assert external_tty_node["id"] not in node_ids

        scroll = run_cli(env, "pane", "scroll", pane_id, "-5", "-1")
        assert "integration-tmux" in scroll["result"]["content"]

        pane_follow = run_cli(env, "pane", "follow-tail", pane_id, "false")
        assert pane_follow["result"]["ok"] is True

        send_keys = run_cli(env, "pane", "send-keys", pane_id, "echo from-send-keys", "--enter")
        assert send_keys["result"]["ok"] is True
        wait_for_node_content(env, session["result"]["nodeId"], "from-send-keys")
        capture = run_cli(env, "pane", "capture", pane_id)
        assert "from-send-keys" in capture["result"]["content"]

        split = run_cli(
            env,
            "pane",
            "split",
            pane_id,
            "right",
            "sh -lc 'printf \"%s\\\\n\" split-pane; sleep 30'",
        )
        assert split["result"]["nodeId"] > 0
        document = run_cli(env, "document", "get")["result"]
        nodes = {node["id"]: node for node in document["nodes"]}
        split_pane_id = nodes[split["result"]["nodeId"]]["source"]["paneId"]

        resize = run_cli(env, "pane", "resize", split_pane_id, "left", "5")
        assert resize["result"]["ok"] is True

        focus = run_cli(env, "pane", "focus", split_pane_id)
        assert focus["result"]["ok"] is True

        window = run_cli(
            env,
            "window",
            "create",
            SESSION_NAME,
            "extra",
            "sh -lc 'printf \"%s\\\\n\" window-pane; sleep 30'",
        )
        assert window["result"]["nodeId"] > 0

        close = run_cli(env, "pane", "close", split_pane_id)
        assert close["result"]["ok"] is True
        document = wait_for_node_absent(env, split["result"]["nodeId"])["result"]
        node_ids = {node["id"] for node in document["nodes"]}
        assert split["result"]["nodeId"] not in node_ids

        drift_session = run_cli(
            env,
            "session",
            "create",
            DRIFT_SESSION_NAME,
            "sh -lc 'printf \"%s\\\\n\" drift-session; sleep 30'",
        )
        assert drift_session["result"]["nodeId"] > 0
        drift_session_node = run_cli(env, "node", "get", str(drift_session["result"]["nodeId"]))
        drift_window_node = run_cli(env, "node", "get", str(drift_session_node["result"]["parentId"]))
        drift_session_container = run_cli(env, "node", "get", str(drift_window_node["result"]["parentId"]))
        subprocess.run(
            ["tmux", "kill-session", "-t", DRIFT_SESSION_NAME],
            cwd=REPO,
            env=env,
            check=True,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )
        document = wait_for_node_absent(env, drift_session_container["result"]["id"])["result"]
        node_ids = {node["id"] for node in document["nodes"]}
        assert drift_session_container["result"]["id"] not in node_ids

        freeze_session = run_cli(
            env,
            "session",
            "create",
            FREEZE_SESSION_NAME,
            "sh -lc 'printf \"%s\\\\n\" freeze-demo; sleep 30'",
        )
        assert freeze_session["result"]["nodeId"] > 0
        freeze_node_before = run_cli(env, "node", "get", str(freeze_session["result"]["nodeId"]))
        freeze_pane_id = freeze_node_before["result"]["source"]["paneId"]
        wait_for_pane_content(env, freeze_pane_id, "freeze-demo")

        frozen = run_cli(env, "node", "freeze", str(freeze_session["result"]["nodeId"]), "text")
        assert frozen["result"]["ok"] is True
        assert frozen["result"]["artifactKind"] == "text"
        assert frozen["result"]["contentFormat"] == "plain_text"
        assert frozen["result"]["sections"] == []

        freeze_node_after = run_cli(env, "node", "get", str(freeze_session["result"]["nodeId"]))
        assert freeze_node_after["result"]["lifecycle"] == "frozen"
        assert freeze_node_after["result"]["source"]["kind"] == "terminal_artifact"
        assert freeze_node_after["result"]["source"]["artifactKind"] == "text"
        assert freeze_node_after["result"]["source"]["contentFormat"] == "plain_text"
        assert freeze_node_after["result"]["source"]["sections"] == []
        assert freeze_node_after["result"]["source"]["origin"] == "tty"
        assert freeze_node_after["result"]["source"]["sessionName"] == FREEZE_SESSION_NAME
        assert freeze_node_after["result"]["source"]["paneId"] == freeze_pane_id
        assert "freeze-demo" in freeze_node_after["result"]["content"]

        post_freeze_send_keys = run_cli(env, "pane", "send-keys", freeze_pane_id, "echo after-freeze", "--enter")
        assert post_freeze_send_keys["result"]["ok"] is True
        post_freeze_capture = run_cli(env, "pane", "capture", freeze_pane_id)
        assert "after-freeze" in post_freeze_capture["result"]["content"]
        document = run_cli(env, "document", "get")["result"]
        frozen_node = next(node for node in document["nodes"] if node["id"] == freeze_session["result"]["nodeId"])
        assert frozen_node["lifecycle"] == "frozen"
        assert frozen_node["source"]["kind"] == "terminal_artifact"
        assert "after-freeze" not in frozen_node["content"]

        freeze_surface_session = run_cli(
            env,
            "session",
            "create",
            FREEZE_SURFACE_SESSION_NAME,
            "sh -lc 'printf \"%s\\\\n\" freeze-surface-demo; sleep 30'",
        )
        assert freeze_surface_session["result"]["nodeId"] > 0
        freeze_surface_node_before = run_cli(env, "node", "get", str(freeze_surface_session["result"]["nodeId"]))
        freeze_surface_pane_id = freeze_surface_node_before["result"]["source"]["paneId"]
        wait_for_pane_content(env, freeze_surface_pane_id, "freeze-surface-demo")

        frozen_surface = run_cli(
            env,
            "node",
            "freeze",
            str(freeze_surface_session["result"]["nodeId"]),
            "surface",
        )
        assert frozen_surface["result"]["ok"] is True
        assert frozen_surface["result"]["artifactKind"] == "surface"
        assert frozen_surface["result"]["contentFormat"] == "sectioned_text"
        assert frozen_surface["result"]["sections"] == ["surface"]

        freeze_surface_node_after = run_cli(env, "node", "get", str(freeze_surface_session["result"]["nodeId"]))
        assert freeze_surface_node_after["result"]["lifecycle"] == "frozen"
        assert freeze_surface_node_after["result"]["source"]["kind"] == "terminal_artifact"
        assert freeze_surface_node_after["result"]["source"]["artifactKind"] == "surface"
        assert freeze_surface_node_after["result"]["source"]["contentFormat"] == "sectioned_text"
        assert freeze_surface_node_after["result"]["source"]["sections"] == ["surface"]
        assert freeze_surface_node_after["result"]["source"]["origin"] == "tty"
        assert freeze_surface_node_after["result"]["source"]["sessionName"] == FREEZE_SURFACE_SESSION_NAME
        assert freeze_surface_node_after["result"]["source"]["paneId"] == freeze_surface_pane_id
        assert "freeze-surface-demo" in freeze_surface_node_after["result"]["content"]

        post_surface_freeze_send_keys = run_cli(
            env,
            "pane",
            "send-keys",
            freeze_surface_pane_id,
            "echo after-surface-freeze",
            "--enter",
        )
        assert post_surface_freeze_send_keys["result"]["ok"] is True
        post_surface_freeze_capture = run_cli(env, "pane", "capture", freeze_surface_pane_id)
        assert "after-surface-freeze" in post_surface_freeze_capture["result"]["content"]
        document = run_cli(env, "document", "get")["result"]
        frozen_surface_node = next(
            node for node in document["nodes"] if node["id"] == freeze_surface_session["result"]["nodeId"]
        )
        assert frozen_surface_node["lifecycle"] == "frozen"
        assert frozen_surface_node["source"]["kind"] == "terminal_artifact"
        assert frozen_surface_node["source"]["artifactKind"] == "surface"
        assert "after-surface-freeze" not in frozen_surface_node["content"]

        artifact_viewer_output = subprocess.check_output(
            [str(REPO / "zig-out/bin/muxview"), "--snapshot"],
            cwd=REPO,
            env=env,
            text=True,
        )
        assert len(artifact_viewer_output) > 0, "snapshot should produce non-empty output"

        document = run_cli(env, "document", "get")["result"]
        node_contents = " ".join(node["content"] for node in document["nodes"])
        assert "freeze-demo" in node_contents, "freeze-demo content should exist in document nodes"
        assert "freeze-surface-demo" in node_contents, "freeze-surface-demo content should exist in document nodes"

        viewer_scope = run_cli(env, "node", "append", "1", "subdocument", "viewer-scope")
        viewer_scope_id = viewer_scope["result"]["nodeId"]
        viewer_child = run_cli(env, "node", "append", str(viewer_scope_id), "scroll_region", "viewer-child")
        viewer_child_id = viewer_child["result"]["nodeId"]
        viewer_child_update = run_cli(env, "node", "update", str(viewer_child_id), "content", "viewer payload")
        assert viewer_child_update["result"]["ok"] is True
        nested_view = run_cli(
            env,
            "session",
            "create-under",
            str(viewer_scope_id),
            NESTED_SESSION_NAME,
            "sh -lc 'printf \"%s\\\\n\" theorem-demo; sleep 30'",
        )
        nested_view_node = run_cli(env, "node", "get", str(nested_view["result"]["nodeId"]))
        nested_window_node = run_cli(env, "node", "get", str(nested_view_node["result"]["parentId"]))
        nested_session_node = run_cli(env, "node", "get", str(nested_window_node["result"]["parentId"]))
        assert nested_session_node["result"]["parentId"] == viewer_scope_id
        nested_view_pane_id = nested_view_node["result"]["source"]["paneId"]
        nested_capture = wait_for_pane_content(env, nested_view_pane_id, "theorem-demo")
        assert "theorem-demo" in nested_capture["result"]["content"]

        nested_split = run_cli(
            env,
            "pane",
            "split",
            nested_view_pane_id,
            "right",
            "sh -lc 'printf \"%s\\\\n\" nested-split; sleep 30'",
        )
        nested_split_node = run_cli(env, "node", "get", str(nested_split["result"]["nodeId"]))
        nested_split_window_node = run_cli(env, "node", "get", str(nested_split_node["result"]["parentId"]))
        nested_split_session_node = run_cli(env, "node", "get", str(nested_split_window_node["result"]["parentId"]))
        assert nested_split_session_node["result"]["id"] == nested_session_node["result"]["id"]
        assert nested_split_session_node["result"]["parentId"] == viewer_scope_id
        nested_split_pane_id = nested_split_node["result"]["source"]["paneId"]
        nested_split_capture = wait_for_pane_content(env, nested_split_pane_id, "nested-split")
        assert "nested-split" in nested_split_capture["result"]["content"]

        root = run_cli(env, "view", "set-root", str(viewer_scope_id))
        assert root["result"]["ok"] is True
        elide = run_cli(env, "view", "elide", str(viewer_child_id))
        assert elide["result"]["ok"] is True

        viewer_output = subprocess.check_output(
            [str(REPO / "zig-out/bin/muxview"), "--snapshot"],
            cwd=REPO,
            env=env,
            text=True,
        )
        assert "+viewer-scope" in viewer_output
        assert "viewer-child" in viewer_output
        assert "... elided by shared view state ..." in viewer_output

        live_view = run_cli(
            env,
            "session",
            "create-under",
            str(viewer_scope_id),
            LIVE_VIEWER_SESSION_NAME,
            "sh",
        )
        live_view_node = run_cli(env, "node", "get", str(live_view["result"]["nodeId"]))
        live_view_pane_id = live_view_node["result"]["source"]["paneId"]

        master_fd, slave_fd = pty.openpty()
        viewer = subprocess.Popen(
            [str(REPO / "zig-out/bin/muxview")],
            cwd=REPO,
            env=env,
            stdin=slave_fd,
            stdout=slave_fd,
            stderr=slave_fd,
            text=False,
        )
        os.close(slave_fd)
        try:
            live_output = wait_for_pty_output(master_fd, b"viewer-scope")
            assert b"viewer-scope" in live_output

            live_send_keys = run_cli(env, "pane", "send-keys", live_view_pane_id, "echo live-pty-refresh", "--enter")
            assert live_send_keys["result"]["ok"] is True
            wait_for_node_content(env, live_view["result"]["nodeId"], "live-pty-refresh")

            refreshed_output = wait_for_pty_output(master_fd, b"\x1b[2J\x1b[H")
            assert b"\x1b[2J\x1b[H" in refreshed_output

            os.write(master_fd, b"q")
            viewer.wait(timeout=5)
            assert viewer.returncode == 0
        finally:
            if viewer.poll() is None:
                viewer.terminate()
                try:
                    viewer.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    viewer.kill()
                    viewer.wait(timeout=5)
            os.close(master_fd)

        nested_split_close = run_cli(env, "pane", "close", nested_split_pane_id)
        assert nested_split_close["result"]["ok"] is True
        document = wait_for_node_absent(env, nested_split["result"]["nodeId"])["result"]
        nested_node_ids = {node["id"] for node in document["nodes"]}
        assert nested_split["result"]["nodeId"] not in nested_node_ids

        nested_close = run_cli(env, "pane", "close", nested_view_pane_id)
        assert nested_close["result"]["ok"] is True
        document = wait_for_node_absent(env, nested_view["result"]["nodeId"])["result"]
        nested_node_ids = {node["id"] for node in document["nodes"]}
        assert nested_view["result"]["nodeId"] not in nested_node_ids
        assert nested_session_node["result"]["id"] not in nested_node_ids

        reset = run_cli(env, "view", "reset")
        assert reset["result"]["ok"] is True
        status = run_cli(env, "document", "status")
        assert status["result"]["viewRootNodeId"] is None

        print("integration test passed")
    finally:
        cleanup_tmux_session(env, SESSION_NAME)
        cleanup_tmux_session(env, NESTED_SESSION_NAME)
        cleanup_tmux_session(env, DRIFT_SESSION_NAME)
        cleanup_tmux_session(env, FREEZE_SESSION_NAME)
        cleanup_tmux_session(env, FREEZE_SURFACE_SESSION_NAME)
        cleanup_tmux_session(env, LIVE_VIEWER_SESSION_NAME)
        daemon.terminate()
        try:
            daemon.wait(timeout=5)
        except subprocess.TimeoutExpired:
            daemon.kill()
            daemon.wait(timeout=5)
        if daemon.stderr:
            daemon.stderr.close()
        try:
            os.remove(SOCKET_PATH)
        except FileNotFoundError:
            pass


if __name__ == "__main__":
    main()

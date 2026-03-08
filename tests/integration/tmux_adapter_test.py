import json
import os
import pathlib
import subprocess
import tempfile
import time


REPO = pathlib.Path(__file__).resolve().parents[2]
SOCKET_PATH = "/tmp/muxly-integration.sock"
SESSION_NAME = "muxly-integration-demo"


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
        if needle in last_capture["result"]["content"].replace("n\n", "\n"):
            return last_capture
        time.sleep(0.1)
    raise AssertionError(
        f"timed out waiting for pane {pane_id} to contain {needle!r}: {last_capture!r}"
    )


def main() -> None:
    env = os.environ.copy()
    env["MUXLY_SOCKET"] = SOCKET_PATH

    try:
        os.remove(SOCKET_PATH)
    except FileNotFoundError:
        pass

    cleanup_tmux_session(env, SESSION_NAME)

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
        assert capabilities["tmuxBackendMode"] == "command-backed"
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
            "sh -lc 'printf integration-tmux\\\\n; sleep 5'",
        )
        assert session["result"]["nodeId"] > 0

        sessions = run_cli(env, "session", "list")
        assert any(item["sessionName"] == SESSION_NAME for item in sessions["result"])

        document = run_cli(env, "document", "get")["result"]
        tty_nodes = [node for node in document["nodes"] if node["kind"] == "tty_leaf"]
        assert tty_nodes, document
        pane_id = tty_nodes[-1]["source"]["paneId"]
        windows = run_cli(env, "window", "list")
        panes = run_cli(env, "pane", "list")
        node = run_cli(env, "node", "get", str(session["result"]["nodeId"]))
        assert any(item["paneId"] == pane_id for item in panes["result"])
        assert node["result"]["id"] == session["result"]["nodeId"]
        assert windows["result"]

        capture = wait_for_pane_content(env, pane_id, "integration-tmux")
        assert "integration-tmux" in capture["result"]["content"].replace("n\n", "\n")

        scroll = run_cli(env, "pane", "scroll", pane_id, "-5", "-1")
        assert "integration-tmux" in scroll["result"]["content"].replace("n\n", "\n")

        pane_follow = run_cli(env, "pane", "follow-tail", pane_id, "false")
        assert pane_follow["result"]["ok"] is True

        send_keys = run_cli(env, "pane", "send-keys", pane_id, "echo from-send-keys", "--enter")
        assert send_keys["result"]["ok"] is True
        time.sleep(0.2)
        capture = run_cli(env, "pane", "capture", pane_id)
        assert "from-send-keys" in capture["result"]["content"]

        split = run_cli(
            env,
            "pane",
            "split",
            pane_id,
            "right",
            "sh -lc 'printf split-pane\\\\n; sleep 5'",
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
            "sh -lc 'printf window-pane\\\\n; sleep 5'",
        )
        assert window["result"]["nodeId"] > 0

        close = run_cli(env, "pane", "close", split_pane_id)
        assert close["result"]["ok"] is True
        document = run_cli(env, "document", "get")["result"]
        node_ids = {node["id"] for node in document["nodes"]}
        assert split["result"]["nodeId"] not in node_ids

        viewer_scope = run_cli(env, "node", "append", "1", "subdocument", "viewer-scope")
        viewer_scope_id = viewer_scope["result"]["nodeId"]
        viewer_child = run_cli(env, "node", "append", str(viewer_scope_id), "scroll_region", "viewer-child")
        viewer_child_id = viewer_child["result"]["nodeId"]
        viewer_child_update = run_cli(env, "node", "update", str(viewer_child_id), "content", "viewer payload")
        assert viewer_child_update["result"]["ok"] is True

        root = run_cli(env, "view", "set-root", str(viewer_scope_id))
        assert root["result"]["ok"] is True
        elide = run_cli(env, "view", "elide", str(viewer_child_id))
        assert elide["result"]["ok"] is True

        viewer_output = subprocess.check_output(
            [str(REPO / "zig-out/bin/muxview")],
            cwd=REPO,
            env=env,
            text=True,
        )
        assert "view-state :: shared-document" in viewer_output
        assert f"scope :: node {viewer_scope_id} (viewer-scope)" in viewer_output
        assert "path :: muxly / viewer-scope" in viewer_output
        assert "back-out :: muxly view clear-root | muxly view reset" in viewer_output
        assert "… elided by shared view state …" in viewer_output

        reset = run_cli(env, "view", "reset")
        assert reset["result"]["ok"] is True
        status = run_cli(env, "document", "status")
        assert status["result"]["viewRootNodeId"] is None

        print("integration test passed")
    finally:
        cleanup_tmux_session(env, SESSION_NAME)
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

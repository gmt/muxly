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


def main() -> None:
    env = os.environ.copy()
    env["MUXLY_SOCKET"] = SOCKET_PATH

    try:
        os.remove(SOCKET_PATH)
    except FileNotFoundError:
        pass

    subprocess.run(["tmux", "kill-session", "-t", SESSION_NAME], cwd=REPO, env=env, check=False)

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

        with tempfile.TemporaryDirectory() as temp_dir:
            static_path = pathlib.Path(temp_dir) / "static.txt"
            static_path.write_text("alpha\nbeta\n")
            monitored_path = pathlib.Path(temp_dir) / "monitored.txt"
            monitored_path.write_text("line-1\n")

            static_attach = run_cli(env, "leaf", "attach-file", "static-file", str(static_path))
            monitored_attach = run_cli(env, "leaf", "attach-file", "monitored-file", str(monitored_path))
            assert static_attach["result"]["nodeId"] > 0
            assert monitored_attach["result"]["nodeId"] > 0

            monitored_path.write_text("line-1\nline-2\n")
            document = run_cli(env, "document", "get")["result"]
            nodes = {node["id"]: node for node in document["nodes"]}
            monitored_node = nodes[monitored_attach["result"]["nodeId"]]
            assert "line-2" in monitored_node["content"]

        session = run_cli(
            env,
            "session",
            "create",
            SESSION_NAME,
            "sh -lc 'printf integration-tmux\\\\n; sleep 5'",
        )
        assert session["result"]["nodeId"] > 0

        document = run_cli(env, "document", "get")["result"]
        tty_nodes = [node for node in document["nodes"] if node["kind"] == "tty_leaf"]
        assert tty_nodes, document
        pane_id = tty_nodes[-1]["source"]["paneId"]

        capture = run_cli(env, "pane", "capture", pane_id)
        assert "integration-tmux" in capture["result"]["content"]

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

        print("integration test passed")
    finally:
        subprocess.run(["tmux", "kill-session", "-t", SESSION_NAME], cwd=REPO, env=env, check=False)
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

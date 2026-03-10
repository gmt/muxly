#!/usr/bin/env python3
import json
import os
import pathlib
import shlex
import subprocess
import sys
import tempfile
import time


REPO = pathlib.Path(__file__).resolve().parents[3]
DEFAULT_SOCKET = "/tmp/muxly-example-tty-basic.sock"
SESSION_NAME = "muxly-example-theorem-stage"
CHATTER_SCRIPT = pathlib.Path(__file__).resolve().with_name("theorem_chatter.py")


def run(env: dict[str, str], *args: str) -> None:
    subprocess.run(args, cwd=REPO, env=env, check=True)


def run_cli(env: dict[str, str], *args: str) -> dict:
    output = subprocess.check_output(
        [str(REPO / "zig-out/bin/muxly"), *args],
        cwd=REPO,
        env=env,
        text=True,
    )
    return json.loads(output)


def daemon_is_alive(env: dict[str, str]) -> bool:
    try:
        subprocess.run(
            [str(REPO / "zig-out/bin/muxly"), "ping"],
            cwd=REPO,
            env=env,
            check=True,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )
        return True
    except (FileNotFoundError, subprocess.CalledProcessError):
        return False


def wait_for_socket(path: str, timeout: float = 5.0) -> None:
    deadline = time.time() + timeout
    while time.time() < deadline:
        if os.path.exists(path):
            return
        time.sleep(0.05)
    raise RuntimeError(f"socket did not appear: {path}")


def read_text(path: pathlib.Path) -> str:
    try:
        return path.read_text()
    except FileNotFoundError:
        return ""


def wait_for_daemon_ready(
    env: dict[str, str],
    socket_path: str,
    daemon: subprocess.Popen[str],
    stderr_path: pathlib.Path,
    timeout: float = 5.0,
) -> None:
    deadline = time.time() + timeout
    socket_seen = False

    while time.time() < deadline:
        if os.path.exists(socket_path):
            socket_seen = True
        if socket_seen and daemon_is_alive(env):
            return
        if daemon.poll() is not None:
            stderr_output = read_text(stderr_path).strip()
            message = f"muxlyd exited early with status {daemon.returncode}"
            if stderr_output:
                message = f"{message}\n{stderr_output}"
            raise RuntimeError(message)
        time.sleep(0.05)

    stderr_output = read_text(stderr_path).strip()
    message = f"socket did not appear: {socket_path}" if not socket_seen else f"muxlyd did not answer ping on {socket_path}"
    if stderr_output:
        message = f"{message}\n{stderr_output}"
    raise RuntimeError(message)


def ensure_daemon(env: dict[str, str], socket_path: str) -> tuple[subprocess.Popen[str] | None, pathlib.Path | None]:
    if daemon_is_alive(env):
        return None, None

    try:
        os.remove(socket_path)
    except FileNotFoundError:
        pass

    stderr_file = tempfile.NamedTemporaryFile(
        mode="w+",
        prefix="muxlyd-tty-example-stderr-",
        suffix=".log",
        delete=False,
    )
    stderr_path = pathlib.Path(stderr_file.name)
    daemon = subprocess.Popen(
        [str(REPO / "zig-out/bin/muxlyd")],
        cwd=REPO,
        env=env,
        stdout=subprocess.DEVNULL,
        stderr=stderr_file,
        text=True,
    )
    stderr_file.close()
    wait_for_daemon_ready(env, socket_path, daemon, stderr_path)
    return daemon, stderr_path


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
    raise RuntimeError(f"timed out waiting for pane {pane_id} to contain {needle!r}: {last_capture!r}")


def main() -> None:
    env = os.environ.copy()
    socket_path = env.get("MUXLY_SOCKET", DEFAULT_SOCKET)
    env["MUXLY_SOCKET"] = socket_path

    run(env, "zig", "build", "example-deps")

    daemon, stderr_path = ensure_daemon(env, socket_path)
    cleanup_tmux_session(env, SESSION_NAME)

    command_body = f"{shlex.quote(sys.executable)} -u {shlex.quote(str(CHATTER_SCRIPT))}"
    session_command = f"sh -lc {shlex.quote(command_body)}"

    try:
        stage = run_cli(env, "node", "append", "1", "subdocument", "theorem-stage")
        stage_id = stage["result"]["nodeId"]

        note = run_cli(env, "node", "append", str(stage_id), "scroll_region", "operator-note")
        note_id = note["result"]["nodeId"]
        run_cli(
            env,
            "node",
            "update",
            str(note_id),
            "content",
            "live theorem chatter below\nscope is pinned to this stage\nshared view state stays explicit",
        )

        tty_node = run_cli(
            env,
            "session",
            "create-under",
            str(stage_id),
            SESSION_NAME,
            session_command,
        )
        tty_node_id = tty_node["result"]["nodeId"]
        tty_node_detail = run_cli(env, "node", "get", str(tty_node_id))
        pane_id = tty_node_detail["result"]["source"]["paneId"]
        wait_for_pane_content(env, pane_id, "goal:")

        run_cli(env, "view", "set-root", str(stage_id))

        viewer_output = subprocess.check_output(
            [str(REPO / "zig-out/bin/muxview")],
            cwd=REPO,
            env=env,
            text=True,
        )
        print(viewer_output, end="")
    finally:
        cleanup_tmux_session(env, SESSION_NAME)
        subprocess.run([str(REPO / "zig-out/bin/muxly"), "view", "reset"], cwd=REPO, env=env, check=False, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        if daemon is not None:
            daemon.terminate()
            try:
                daemon.wait(timeout=5)
            except subprocess.TimeoutExpired:
                daemon.kill()
                daemon.wait(timeout=5)
            try:
                os.remove(socket_path)
            except FileNotFoundError:
                pass
        if stderr_path is not None:
            try:
                stderr_path.unlink()
            except FileNotFoundError:
                pass


if __name__ == "__main__":
    main()

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
DEFAULT_SOCKET = "/tmp/muxly-example-freeze.sock"
TEXT_SESSION_NAME = "muxly-example-freeze-text"
SURFACE_SESSION_NAME = "muxly-example-freeze-surface"
SURFACE_SCRIPT = pathlib.Path(__file__).resolve().with_name("surface_chatter.py")


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
    while time.time() < deadline:
        if os.path.exists(socket_path) and daemon_is_alive(env):
            return
        if daemon.poll() is not None:
            stderr_output = read_text(stderr_path).strip()
            message = f"muxlyd exited early with status {daemon.returncode}"
            if stderr_output:
                message = f"{message}\n{stderr_output}"
            raise RuntimeError(message)
        time.sleep(0.05)

    stderr_output = read_text(stderr_path).strip()
    message = f"muxlyd did not answer ping on {socket_path}"
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
        prefix="muxlyd-artifact-example-stderr-",
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


def wait_for_pane_content(env: dict[str, str], pane_id: str, needle: str, timeout: float = 4.0) -> dict:
    deadline = time.time() + timeout
    last_capture: dict | None = None
    while time.time() < deadline:
        last_capture = run_cli(env, "pane", "capture", pane_id)
        if needle in last_capture["result"]["content"].replace("n\n", "\n"):
            return last_capture
        time.sleep(0.1)
    raise RuntimeError(f"timed out waiting for pane {pane_id} to contain {needle!r}: {last_capture!r}")


def print_section(title: str, payload: dict) -> None:
    print(f"\n== {title} ==")
    print(json.dumps(payload["result"], indent=2))


def parse_sectioned_text(content: str) -> dict[str, str]:
    sections: dict[str, list[str]] = {}
    current = "body"
    sections[current] = []

    for line in content.splitlines():
        if line.startswith("[") and line.endswith("]") and len(line) > 2:
            current = line[1:-1]
            sections.setdefault(current, [])
            continue
        sections.setdefault(current, []).append(line)

    return {name: "\n".join(lines).rstrip("\n") for name, lines in sections.items()}


def main() -> None:
    env = os.environ.copy()
    socket_path = env.get("MUXLY_SOCKET", DEFAULT_SOCKET)
    env["MUXLY_SOCKET"] = socket_path

    run(env, "zig", "build", "example-deps")

    daemon, stderr_path = ensure_daemon(env, socket_path)
    cleanup_tmux_session(env, TEXT_SESSION_NAME)
    cleanup_tmux_session(env, SURFACE_SESSION_NAME)

    surface_body = f"{shlex.quote(sys.executable)} -u {shlex.quote(str(SURFACE_SCRIPT))}"
    surface_command = f"sh -lc {shlex.quote(surface_body)}"

    try:
        text_session = run_cli(
            env,
            "session",
            "create",
            TEXT_SESSION_NAME,
            "sh -lc 'printf artifact-text-demo\\n; sleep 5'",
        )
        text_node_id = text_session["result"]["nodeId"]
        text_node = run_cli(env, "node", "get", str(text_node_id))
        text_pane_id = text_node["result"]["source"]["paneId"]
        wait_for_pane_content(env, text_pane_id, "artifact-text-demo")
        frozen_text = run_cli(env, "node", "freeze", str(text_node_id), "text")
        frozen_text_node = run_cli(env, "node", "get", str(text_node_id))

        surface_session = run_cli(
            env,
            "session",
            "create",
            SURFACE_SESSION_NAME,
            surface_command,
        )
        surface_node_id = surface_session["result"]["nodeId"]
        surface_node = run_cli(env, "node", "get", str(surface_node_id))
        surface_pane_id = surface_node["result"]["source"]["paneId"]
        wait_for_pane_content(env, surface_pane_id, "muxly surface demo")
        frozen_surface = run_cli(env, "node", "freeze", str(surface_node_id), "surface")
        frozen_surface_node = run_cli(env, "node", "get", str(surface_node_id))

        print("muxly artifact freeze demo")
        print(f"socket path: {socket_path}")
        print_section("text freeze response", frozen_text)
        print_section("text frozen node", frozen_text_node)
        print_section("surface freeze response", frozen_surface)
        print_section("surface frozen node", frozen_surface_node)
        print("\n== parsed surface sections ==")
        print(json.dumps(parse_sectioned_text(frozen_surface_node["result"]["content"]), indent=2))
    finally:
        cleanup_tmux_session(env, TEXT_SESSION_NAME)
        cleanup_tmux_session(env, SURFACE_SESSION_NAME)
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

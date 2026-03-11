#!/usr/bin/env python3
import ctypes
import json
import os
import pathlib
import shlex
import subprocess
import sys
import tempfile
import time


REPO = pathlib.Path(__file__).resolve().parents[3]
LIBMUXLY = REPO / "zig-out/lib/libmuxly.so"
DEFAULT_SOCKET = "/tmp/muxly-example-python-freeze.sock"
TEXT_SESSION_NAME = "muxly-example-python-freeze-text"
SURFACE_SESSION_NAME = "muxly-example-python-freeze-surface"
SURFACE_SCRIPT = REPO / "examples/artifacts/freeze-demo/surface_chatter.py"


def run(env: dict[str, str], *args: str) -> None:
    subprocess.run(args, cwd=REPO, env=env, check=True)


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
        prefix="muxlyd-python-freeze-example-stderr-",
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


def configure_lib() -> ctypes.CDLL:
    lib = ctypes.CDLL(str(LIBMUXLY))
    lib.muxly_version.restype = ctypes.c_char_p
    lib.muxly_client_create.argtypes = [ctypes.c_char_p]
    lib.muxly_client_create.restype = ctypes.c_void_p
    lib.muxly_client_destroy.argtypes = [ctypes.c_void_p]
    lib.muxly_client_session_create.argtypes = [ctypes.c_void_p, ctypes.c_char_p, ctypes.c_char_p]
    lib.muxly_client_session_create.restype = ctypes.c_void_p
    lib.muxly_client_node_get.argtypes = [ctypes.c_void_p, ctypes.c_ulonglong]
    lib.muxly_client_node_get.restype = ctypes.c_void_p
    lib.muxly_client_node_freeze.argtypes = [ctypes.c_void_p, ctypes.c_ulonglong, ctypes.c_char_p]
    lib.muxly_client_node_freeze.restype = ctypes.c_void_p
    lib.muxly_client_pane_capture.argtypes = [ctypes.c_void_p, ctypes.c_char_p]
    lib.muxly_client_pane_capture.restype = ctypes.c_void_p
    lib.muxly_string_free.argtypes = [ctypes.c_void_p]
    return lib


def call_json(lib: ctypes.CDLL, ptr: int | None) -> dict:
    if not ptr:
        raise RuntimeError("libmuxly call failed")
    try:
        payload = ctypes.cast(ptr, ctypes.c_char_p).value
        if payload is None:
            raise RuntimeError("libmuxly returned a null string payload")
        return json.loads(payload.decode())
    finally:
        lib.muxly_string_free(ptr)


def wait_for_pane_content(lib: ctypes.CDLL, client: int, pane_id: str, needle: str, timeout: float = 4.0) -> dict:
    deadline = time.time() + timeout
    last_capture: dict | None = None
    pane_bytes = pane_id.encode()
    while time.time() < deadline:
        last_capture = call_json(lib, lib.muxly_client_pane_capture(client, pane_bytes))
        if needle in last_capture["result"]["content"]:
            return last_capture
        time.sleep(0.1)
    raise RuntimeError(f"timed out waiting for pane {pane_id} to contain {needle!r}: {last_capture!r}")


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


def print_section(title: str, payload: dict) -> None:
    print(f"\n== {title} ==")
    print(json.dumps(payload["result"], indent=2))


def main() -> None:
    env = os.environ.copy()
    socket_path = env.get("MUXLY_SOCKET", DEFAULT_SOCKET)
    env["MUXLY_SOCKET"] = socket_path

    library_dir = str(REPO / "zig-out/lib")
    env["LD_LIBRARY_PATH"] = (
        library_dir
        if "LD_LIBRARY_PATH" not in env
        else f"{library_dir}:{env['LD_LIBRARY_PATH']}"
    )

    run(env, "zig", "build", "example-deps")

    daemon, stderr_path = ensure_daemon(env, socket_path)
    cleanup_tmux_session(env, TEXT_SESSION_NAME)
    cleanup_tmux_session(env, SURFACE_SESSION_NAME)

    lib = configure_lib()
    client = lib.muxly_client_create(socket_path.encode())
    if not client:
        raise SystemExit("client create failed")

    surface_body = f"{shlex.quote(sys.executable)} -u {shlex.quote(str(SURFACE_SCRIPT))}"
    surface_command = f"sh -lc {shlex.quote(surface_body)}"

    try:
        print("muxly version:", lib.muxly_version().decode())
        print("socket path:", socket_path)

        text_session = call_json(
            lib,
            lib.muxly_client_session_create(
                client,
                TEXT_SESSION_NAME.encode(),
                b"sh -lc 'printf \"%s\\n\" python-freeze-text; sleep 5'",
            ),
        )
        text_node_id = text_session["result"]["nodeId"]
        text_node = call_json(lib, lib.muxly_client_node_get(client, text_node_id))
        text_pane_id = text_node["result"]["source"]["paneId"]
        wait_for_pane_content(lib, client, text_pane_id, "python-freeze-text")
        frozen_text = call_json(lib, lib.muxly_client_node_freeze(client, text_node_id, b"text"))
        frozen_text_node = call_json(lib, lib.muxly_client_node_get(client, text_node_id))

        surface_session = call_json(
            lib,
            lib.muxly_client_session_create(
                client,
                SURFACE_SESSION_NAME.encode(),
                surface_command.encode(),
            ),
        )
        surface_node_id = surface_session["result"]["nodeId"]
        surface_node = call_json(lib, lib.muxly_client_node_get(client, surface_node_id))
        surface_pane_id = surface_node["result"]["source"]["paneId"]
        wait_for_pane_content(lib, client, surface_pane_id, "muxly surface demo")
        frozen_surface = call_json(lib, lib.muxly_client_node_freeze(client, surface_node_id, b"surface"))
        frozen_surface_node = call_json(lib, lib.muxly_client_node_get(client, surface_node_id))

        print_section("text freeze response", frozen_text)
        print_section("text frozen node", frozen_text_node)
        print_section("surface freeze response", frozen_surface)
        print_section("surface frozen node", frozen_surface_node)
        print("\n== parsed surface sections ==")
        print(json.dumps(parse_sectioned_text(frozen_surface_node["result"]["content"]), indent=2))
    finally:
        lib.muxly_client_destroy(client)
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

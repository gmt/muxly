#!/usr/bin/env python3
import argparse
import os
import pathlib
import subprocess
import sys
import tempfile
import time


REPO = pathlib.Path(__file__).resolve().parents[1]
DEFAULT_SOCKETS = {
    "c": "/tmp/muxly-example-c.sock",
    "zig": "/tmp/muxly-example-zig.sock",
    "python": "/tmp/muxly-example-python.sock",
}


def wait_for_socket(path: str, timeout: float = 5.0) -> None:
    deadline = time.time() + timeout
    while time.time() < deadline:
        if os.path.exists(path):
            return
        time.sleep(0.05)
    raise RuntimeError(f"socket did not appear: {path}")


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
    if socket_seen:
        message = f"muxlyd did not answer ping on {socket_path}"
    else:
        message = f"socket did not appear: {socket_path}"
    if stderr_output:
        message = f"{message}\n{stderr_output}"
    raise RuntimeError(message)


def ensure_daemon(
    env: dict[str, str],
    socket_path: str,
) -> tuple[subprocess.Popen[str] | None, pathlib.Path | None]:
    if daemon_is_alive(env):
        return None, None

    try:
        os.remove(socket_path)
    except FileNotFoundError:
        pass

    stderr_file = tempfile.NamedTemporaryFile(
        mode="w+",
        prefix="muxlyd-example-stderr-",
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


def run_c_example(env: dict[str, str]) -> None:
    run(env, "make", "-C", "examples/tom/c", "all")
    run(env, str(REPO / "examples/tom/c/basic_client"))


def run_zig_example(env: dict[str, str]) -> None:
    run(
        env,
        "zig",
        "run",
        "examples/tom/zig/basic_client.zig",
        "-lc",
        "-Izig-out/include",
        "-Lzig-out/lib",
        "-lmuxly",
    )


def run_python_example(env: dict[str, str]) -> None:
    run(env, "python3", "examples/tom/python/basic_client.py")


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("example", choices=("c", "zig", "python"))
    args = parser.parse_args()

    env = os.environ.copy()
    socket_path = env.get("MUXLY_SOCKET", DEFAULT_SOCKETS[args.example])
    env["MUXLY_SOCKET"] = socket_path

    library_dir = str(REPO / "zig-out/lib")
    env["LD_LIBRARY_PATH"] = (
        library_dir
        if "LD_LIBRARY_PATH" not in env
        else f"{library_dir}:{env['LD_LIBRARY_PATH']}"
    )

    run(env, "zig", "build", "example-deps")

    daemon, stderr_path = ensure_daemon(env, socket_path)

    try:
        if args.example == "c":
            run_c_example(env)
        elif args.example == "zig":
            run_zig_example(env)
        else:
            run_python_example(env)
    finally:
        if daemon is not None:
            daemon.terminate()
            try:
                daemon.wait(timeout=5)
            except subprocess.TimeoutExpired:
                daemon.kill()
                daemon.wait(timeout=5)
            if daemon.stderr:
                daemon.stderr.close()
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
    try:
        main()
    except Exception as exc:
        print(exc, file=sys.stderr)
        raise

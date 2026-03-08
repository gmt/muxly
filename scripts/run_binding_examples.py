#!/usr/bin/env python3
import os
import pathlib
import subprocess
import sys
import time


REPO = pathlib.Path(__file__).resolve().parents[1]
SOCKET_PATH = os.environ.get("MUXLY_SOCKET", "/tmp/muxly-bindings.sock")


def wait_for_socket(path: str, timeout: float = 5.0) -> None:
    deadline = time.time() + timeout
    while time.time() < deadline:
        if os.path.exists(path):
            return
        time.sleep(0.05)
    raise RuntimeError(f"socket did not appear: {path}")


def run(env: dict[str, str], *args: str) -> None:
    subprocess.run(args, cwd=REPO, env=env, check=True)


def main() -> None:
    env = os.environ.copy()
    env["MUXLY_SOCKET"] = SOCKET_PATH
    library_dir = str(REPO / "zig-out/lib")
    env["LD_LIBRARY_PATH"] = (
        library_dir
        if "LD_LIBRARY_PATH" not in env
        else f"{library_dir}:{env['LD_LIBRARY_PATH']}"
    )

    c_example = pathlib.Path("/tmp/muxly-c-basic-client")

    try:
        os.remove(SOCKET_PATH)
    except FileNotFoundError:
        pass

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

        run(
            env,
            "cc",
            "examples/c/basic_client.c",
            "-Izig-out/include",
            "-Lzig-out/lib",
            f"-Wl,-rpath,{library_dir}",
            "-lmuxly",
            "-o",
            str(c_example),
        )
        run(env, str(c_example))
        run(
            env,
            "zig",
            "run",
            "examples/zig/basic_client.zig",
            "-lc",
            "-Izig-out/include",
            "-Lzig-out/lib",
            "-lmuxly",
        )
        run(env, "python3", "examples/python/basic_client.py")

        print("binding examples passed")
    finally:
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
        try:
            c_example.unlink()
        except FileNotFoundError:
            pass


if __name__ == "__main__":
    try:
        main()
    except Exception as exc:
        print(exc, file=sys.stderr)
        raise

#!/usr/bin/env python3
import os
import pathlib
import subprocess
import sys


REPO = pathlib.Path(__file__).resolve().parents[1]

EXAMPLES = [
    ("c-freeze", REPO / "examples/artifacts/c-freeze/run.sh"),
    ("freeze-demo", REPO / "examples/artifacts/freeze-demo/run.sh"),
    ("python-freeze", REPO / "examples/artifacts/python-freeze/run.sh"),
    ("zig-freeze", REPO / "examples/artifacts/zig-freeze/run.sh"),
]


def run(env: dict[str, str], path: pathlib.Path) -> None:
    subprocess.run([str(path)], cwd=REPO, env=env, check=True)


def main() -> None:
    env = os.environ.copy()

    for name, path in EXAMPLES:
        print(f"== running artifact example: {name} ==", flush=True)
        run(env, path)
        print(flush=True)


if __name__ == "__main__":
    try:
        main()
    except Exception as exc:
        print(exc, file=sys.stderr)
        raise

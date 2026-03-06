#!/usr/bin/env python3
import shutil
import subprocess


def main() -> None:
    if shutil.which("tmux") is None:
        raise SystemExit("tmux not found")

    subprocess.run(["tmux", "-V"], check=True)
    print("tmux environment looks available")


if __name__ == "__main__":
    main()

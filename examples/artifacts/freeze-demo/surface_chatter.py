#!/usr/bin/env python3
import sys
import time
import signal


FRAMES = [
    [
        "muxly surface demo",
        "+----------------------+",
        "| theorem depth: 3     |",
        "| mirror tail: warm    |",
        "| counterexample: no   |",
        "+----------------------+",
    ],
    [
        "muxly surface demo",
        "+----------------------+",
        "| theorem depth: 4     |",
        "| mirror tail: hotter  |",
        "| counterexample: no   |",
        "+----------------------+",
    ],
    [
        "muxly surface demo",
        "+----------------------+",
        "| theorem depth: 5     |",
        "| mirror tail: glowing |",
        "| counterexample: ?    |",
        "+----------------------+",
    ],
]

IN_ALT_SCREEN = False


def enter_alt_screen() -> None:
    global IN_ALT_SCREEN
    if IN_ALT_SCREEN:
        return
    sys.stdout.write("\x1b[?1049h\x1b[2J\x1b[H")
    sys.stdout.flush()
    IN_ALT_SCREEN = True


def leave_alt_screen() -> None:
    global IN_ALT_SCREEN
    if not IN_ALT_SCREEN:
        return
    sys.stdout.write("\x1b[?1049l")
    sys.stdout.flush()
    IN_ALT_SCREEN = False


def handle_shutdown(signum, frame) -> None:
    leave_alt_screen()
    raise SystemExit(0)


def main() -> None:
    signal.signal(signal.SIGTERM, handle_shutdown)
    signal.signal(signal.SIGINT, handle_shutdown)
    enter_alt_screen()
    while True:
        for frame in FRAMES:
            sys.stdout.write("\x1b[2J\x1b[H")
            sys.stdout.write("\n".join(frame))
            sys.stdout.write("\n")
            sys.stdout.flush()
            time.sleep(0.35)


if __name__ == "__main__":
    main()

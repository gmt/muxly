#!/usr/bin/env python3
import sys
import time


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


def main() -> None:
    while True:
        for frame in FRAMES:
            sys.stdout.write("\x1b[2J\x1b[H")
            sys.stdout.write("\n".join(frame))
            sys.stdout.write("\n")
            sys.stdout.flush()
            time.sleep(0.35)


if __name__ == "__main__":
    main()

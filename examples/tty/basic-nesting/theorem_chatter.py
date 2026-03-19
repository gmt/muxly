#!/usr/bin/env python3
import argparse
import itertools
import sys
import time


ROLE_SCREENS = {
    "editor": {
        "title": "editor :: src/viewer/main.zig",
        "body": [
            "1 fn attach_viewer(socket_path: []const u8) !void {{",
            "2     const projection = try viewer.project(stage, viewport);",
            "3     try projection.refresh();",
            "4     return projection.attach();",
            "5 }}",
        ],
        "footer": [
            "cursor :: line {line} col {col}",
            "status :: alt-screen live, viewport tracking steady",
        ],
    },
    "errors": {
        "title": "errors :: zig build",
        "body": [
            "src/viewer/main.zig:{line}:13: note: viewer attachment repainted",
            "src/viewer/render.zig:{col}:5: warning: clipped frame avoided",
            "tests/integration: live redraw witness present",
            "build status :: {status}",
            "next pass :: keep snapshot mode explicit and boring",
        ],
        "footer": [
            "watch :: q exits the attached viewer, not the TOM",
            "tmux :: still a substrate, not the constitution",
        ],
    },
    "relay": {
        "title": "relay :: planner to workers",
        "body": [
            "expensive idea #{idea}: flatten stage ownership without panic",
            "worker-a :: re-check pane provenance and lifecycle cues",
            "worker-b :: keep public surfaces honest under redraw",
            "worker-c :: project nested tty chatter into one collaboration space",
            "broadcast :: vim on the left, compile errors on the right",
        ],
        "footer": [
            "formation :: planner -> relay -> shells",
            "force multiplier :: costly thought, cheap actors, shared stage",
        ],
    },
}

STATUS_ROTATION = [
    "0 errors, 2 warnings",
    "1 warning left",
    "tests green",
]


def render_screen(role: str, tick: int) -> str:
    config = ROLE_SCREENS[role]
    line = 18 + (tick % 7)
    col = 9 + ((tick * 3) % 16)
    idea = 100 + tick
    status = STATUS_ROTATION[tick % len(STATUS_ROTATION)]

    rendered = [config["title"]]
    for template in config["body"]:
        rendered.append(
            template.format(
                tick=tick,
                line=line,
                col=col,
                idea=idea,
                status=status,
            )
        )
    for template in config["footer"]:
        rendered.append(
            template.format(
                tick=tick,
                line=line,
                col=col,
                idea=idea,
                status=status,
            )
        )
    return "\n".join(rendered)


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--role", choices=sorted(ROLE_SCREENS), default="editor")
    parser.add_argument("--delay", type=float, default=0.22)
    args = parser.parse_args()

    frames = itertools.count()
    sys.stdout.write("\x1b[2J")
    sys.stdout.flush()

    for tick in frames:
        sys.stdout.write("\x1b[H")
        sys.stdout.write(render_screen(args.role, tick))
        sys.stdout.write("\n")
        sys.stdout.flush()
        time.sleep(args.delay)


if __name__ == "__main__":
    main()

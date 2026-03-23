#!/usr/bin/env python3
import argparse
import os
import signal
import subprocess
import sys


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Run a command with a wall-clock timeout and kill its process group on expiry."
    )
    parser.add_argument(
        "--timeout-seconds",
        type=float,
        required=True,
        help="maximum wall-clock runtime before the command is terminated",
    )
    parser.add_argument(
        "--grace-seconds",
        type=float,
        default=5.0,
        help="additional time to wait after terminate before force-killing",
    )
    parser.add_argument(
        "command",
        nargs=argparse.REMAINDER,
        help="command to execute, usually after `--`",
    )
    args = parser.parse_args()
    if args.command and args.command[0] == "--":
        args.command = args.command[1:]
    if not args.command:
        parser.error("missing command to execute")
    if args.timeout_seconds <= 0:
        parser.error("--timeout-seconds must be greater than zero")
    if args.grace_seconds < 0:
        parser.error("--grace-seconds must be zero or greater")
    return args


def terminate_process_group(proc: subprocess.Popen[bytes]) -> None:
    if os.name == "posix":
        try:
            os.killpg(proc.pid, signal.SIGTERM)
        except ProcessLookupError:
            pass
    else:
        proc.terminate()


def kill_process_group(proc: subprocess.Popen[bytes]) -> None:
    if os.name == "posix":
        try:
            os.killpg(proc.pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
    else:
        proc.kill()


def main() -> int:
    args = parse_args()

    popen_kwargs: dict[str, object] = {}
    if os.name == "posix":
        popen_kwargs["start_new_session"] = True
    elif os.name == "nt":
        popen_kwargs["creationflags"] = subprocess.CREATE_NEW_PROCESS_GROUP

    proc = subprocess.Popen(args.command, **popen_kwargs)
    try:
        return proc.wait(timeout=args.timeout_seconds)
    except subprocess.TimeoutExpired:
        print(
            f"timed out after {args.timeout_seconds:.1f}s: {' '.join(args.command)}",
            file=sys.stderr,
            flush=True,
        )
        terminate_process_group(proc)
        try:
            proc.wait(timeout=args.grace_seconds)
            return 124
        except subprocess.TimeoutExpired:
            kill_process_group(proc)
            proc.wait()
            return 124
    except KeyboardInterrupt:
        terminate_process_group(proc)
        try:
            return proc.wait(timeout=args.grace_seconds)
        except subprocess.TimeoutExpired:
            kill_process_group(proc)
            proc.wait()
            return 130


if __name__ == "__main__":
    raise SystemExit(main())

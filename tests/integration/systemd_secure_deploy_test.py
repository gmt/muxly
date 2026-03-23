#!/usr/bin/env python3
"""Opt-in smoke test for generated user-mode trds deployment artifacts."""

from __future__ import annotations

import json
import os
import pathlib
import shutil
import subprocess
import sys
import tempfile
import time


REPO = pathlib.Path(__file__).resolve().parents[2]
TMP_ROOT = pathlib.Path("/tmp/muxlyd-service-sandbox")
DESCRIPTOR = "trds://127.0.0.1:9443/rpc"
UPSTREAM_PORT = "29443"


def run(cmd: list[str], *, cwd: pathlib.Path | None = None, check: bool = True) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        cmd,
        cwd=cwd or REPO,
        text=True,
        capture_output=True,
        check=check,
    )


def require_tool(name: str) -> None:
    if shutil.which(name) is None:
        raise RuntimeError(f"required tool not found: {name}")


def user_unit_dir() -> pathlib.Path:
    xdg_config = os.environ.get("XDG_CONFIG_HOME")
    if xdg_config:
        return pathlib.Path(xdg_config) / "systemd" / "user"
    return pathlib.Path.home() / ".config" / "systemd" / "user"


def remove_link(unit_name: str) -> None:
    linked = user_unit_dir() / unit_name
    if linked.exists() or linked.is_symlink():
        linked.unlink()


def wait_for_file(path: pathlib.Path, timeout_s: float = 10.0) -> None:
    deadline = time.time() + timeout_s
    while time.time() < deadline:
        if path.exists():
            return
        time.sleep(0.1)
    raise TimeoutError(f"timed out waiting for {path}")


def wait_for_https(root_cert: pathlib.Path) -> dict:
    payload = json.dumps({"jsonrpc": "2.0", "id": 1, "method": "ping", "params": {}})
    deadline = time.time() + 15.0
    last_error: str | None = None
    while time.time() < deadline:
        result = run(
            [
                "curl",
                "--silent",
                "--show-error",
                "--fail",
                "--cacert",
                str(root_cert),
                "-H",
                "content-type: application/json",
                "--data",
                payload,
                "https://127.0.0.1:9443/rpc",
            ],
            check=False,
        )
        if result.returncode == 0:
            return json.loads(result.stdout)
        last_error = result.stderr.strip() or result.stdout.strip()
        time.sleep(0.2)
    raise RuntimeError(f"timed out waiting for HTTPS ping: {last_error}")


def main() -> int:
    if os.environ.get("MUXLY_ENABLE_SYSTEMD_USER_TESTS") != "1":
        print("skipping: set MUXLY_ENABLE_SYSTEMD_USER_TESTS=1 to run", file=sys.stderr)
        return 0

    require_tool("systemctl")
    require_tool("caddy")
    require_tool("curl")

    run(["systemctl", "--user", "is-system-running"], check=False)
    run(["zig", "build", "muxly", "muxlyd"])

    muxly_bin = REPO / "zig-out/bin/muxly"
    muxlyd_bin = REPO / "zig-out/bin/muxlyd"

    with tempfile.TemporaryDirectory(prefix="systemd-secure-", dir=TMP_ROOT) as temp_dir:
        out_dir = pathlib.Path(temp_dir)

        common = [
            "--descriptor",
            DESCRIPTOR,
            "--mode",
            "user",
            "--output-dir",
            str(out_dir),
            "--upstream-port",
            UPSTREAM_PORT,
            "--muxlyd-bin",
            str(muxlyd_bin),
            "--caddy-bin",
            "/usr/bin/caddy",
        ]
        run([str(muxly_bin), "admin", "generate-caddy", *common])
        run([str(muxly_bin), "admin", "generate-systemd", *common])

        muxlyd_unit = next(out_dir.glob("muxlyd-*.service"))
        caddy_unit = next(out_dir.glob("muxly-caddy-*.service"))

        unit_names = [muxlyd_unit.name, caddy_unit.name]
        try:
            run(["systemctl", "--user", "link", str(muxlyd_unit), str(caddy_unit)])
            run(["systemctl", "--user", "daemon-reload"])
            run(["systemctl", "--user", "start", muxlyd_unit.name])
            run(["systemctl", "--user", "start", caddy_unit.name])

            root_cert = out_dir / "caddy-data" / "caddy" / "pki" / "authorities" / "local" / "root.crt"
            wait_for_file(root_cert)
            response = wait_for_https(root_cert)
            assert response["result"]["pong"] is True, response
        finally:
            for unit in reversed(unit_names):
                run(["systemctl", "--user", "stop", unit], check=False)
            for unit in unit_names:
                remove_link(unit)
            run(["systemctl", "--user", "daemon-reload"], check=False)
            for unit in unit_names:
                run(["systemctl", "--user", "reset-failed", unit], check=False)

    return 0


if __name__ == "__main__":
    raise SystemExit(main())

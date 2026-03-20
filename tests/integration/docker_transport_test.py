import argparse
import json
import os
import pathlib
import socket
import subprocess
import tempfile
import time
import uuid


REPO = pathlib.Path(__file__).resolve().parents[2]
IMAGE_TAG = "muxly/docker-transport-test:local"
SSH_USER = "muxlytest"
REMOTE_TCP_PORT = 4488
UNSAFE_TCP_FLAG = "--i-know-this-is-unencrypted-and-unauthenticated"


def run_checked(*args: str, env: dict[str, str] | None = None, text: bool = True) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        list(args),
        cwd=REPO,
        env=env,
        text=text,
        check=True,
        capture_output=True,
    )


def run_cli(env: dict[str, str], *args: str) -> dict:
    completed = run_checked(str(REPO / "zig-out/bin/muxly"), *args, env=env)
    return json.loads(completed.stdout)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Run Docker-backed TCP and SSH transport integration coverage.")
    parser.add_argument(
        "--skip-build",
        action="store_true",
        help="assume zig-out/bin/muxly and zig-out/bin/muxlyd already exist",
    )
    return parser.parse_args()


def build_binaries() -> None:
    subprocess.run(
        ["zig", "build", "muxly", "muxlyd"],
        cwd=REPO,
        check=True,
    )


def build_image() -> None:
    subprocess.run(
        [
            "docker",
            "build",
            "-t",
            IMAGE_TAG,
            str(REPO / "tests/integration/docker_transport_host"),
        ],
        cwd=REPO,
        check=True,
    )


def write_ssh_client_config(config_path: pathlib.Path, private_key_path: pathlib.Path) -> None:
    config_path.parent.mkdir(parents=True, exist_ok=True)
    config_path.write_text(
        "\n".join(
            [
                "Host 127.0.0.1",
                f"  IdentityFile {private_key_path}",
                "  IdentitiesOnly yes",
                "  StrictHostKeyChecking no",
                "  UserKnownHostsFile /dev/null",
                "  BatchMode yes",
                "  LogLevel ERROR",
                "",
            ]
        )
    )
    os.chmod(config_path.parent, 0o700)
    os.chmod(config_path, 0o600)


def select_non_loopback_host_ipv4() -> str:
    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    try:
        sock.connect(("8.8.8.8", 80))
        ip = sock.getsockname()[0]
    finally:
        sock.close()

    if ip.startswith("127."):
        raise RuntimeError(f"resolved only a loopback IPv4 address: {ip}")
    return ip


def parse_docker_port_host_port(output: str) -> int:
    for line in output.splitlines():
        endpoint = line.strip()
        if endpoint.startswith("0.0.0.0:") or endpoint.startswith("127.0.0.1:"):
            return int(endpoint.rsplit(":", 1)[1])
    first = output.splitlines()[0].strip()
    return int(first.rsplit(":", 1)[1])


def wait_for_tcp_ping(
    env: dict[str, str],
    transport_spec: str,
    timeout: float = 10.0,
    require_unsafe_flag: bool = False,
) -> dict:
    deadline = time.time() + timeout
    last_error: Exception | None = None
    while time.time() < deadline:
        try:
            args = ["--transport", transport_spec]
            if require_unsafe_flag:
                args.append(UNSAFE_TCP_FLAG)
            args.append("ping")
            return run_cli(env, *args)
        except Exception as exc:  # noqa: BLE001
            last_error = exc
            time.sleep(0.2)
    raise AssertionError(f"timed out waiting for tcp ping on {transport_spec!r}: {last_error!r}")


def run_transport_relay(env: dict[str, str], transport_spec: str, requests: list[dict]) -> list[dict]:
    payload = "\n".join(json.dumps(request) for request in requests) + "\n"
    proc = subprocess.run(
        [
            str(REPO / "zig-out/bin/muxly"),
            "--transport",
            transport_spec,
            "transport",
            "relay",
        ],
        cwd=REPO,
        env=env,
        text=True,
        input=payload,
        capture_output=True,
        check=True,
    )
    return [json.loads(line) for line in proc.stdout.splitlines() if line.strip()]


def main() -> None:
    args = parse_args()

    if not args.skip_build:
        build_binaries()
    build_image()

    container_name = f"muxly-docker-transport-{uuid.uuid4().hex[:12]}"
    container_id = None

    with tempfile.TemporaryDirectory(prefix="muxly-docker-transport-") as temp_dir_str:
        temp_dir = pathlib.Path(temp_dir_str)
        ssh_key_path = temp_dir / "id_ed25519"
        subprocess.run(
            [
                "ssh-keygen",
                "-q",
                "-t",
                "ed25519",
                "-N",
                "",
                "-f",
                str(ssh_key_path),
            ],
            cwd=REPO,
            check=True,
        )
        public_key = ssh_key_path.with_suffix(".pub").read_text().strip()

        ssh_config_path = temp_dir / "ssh-config"
        write_ssh_client_config(ssh_config_path, ssh_key_path)

        env = os.environ.copy()
        env["MUXLY_SSH_CONFIG"] = str(ssh_config_path)
        host_tcp_ip = select_non_loopback_host_ipv4()

        try:
            container_id = run_checked(
                "docker",
                "run",
                "-d",
                "--rm",
                "--name",
                container_name,
                "-e",
                f"TEST_PUBLIC_KEY={public_key}",
                "-v",
                f"{REPO}:/workspace:ro",
                "-p",
                "127.0.0.1::22",
                "-p",
                f"0.0.0.0::{REMOTE_TCP_PORT}",
                IMAGE_TAG,
                env=env,
            ).stdout.strip()

            ssh_port_output = run_checked("docker", "port", container_name, "22/tcp", env=env).stdout.strip()
            ssh_port = parse_docker_port_host_port(ssh_port_output)
            tcp_port_output = run_checked(
                "docker",
                "port",
                container_name,
                f"{REMOTE_TCP_PORT}/tcp",
                env=env,
            ).stdout.strip()
            host_tcp_port = parse_docker_port_host_port(tcp_port_output)

            subprocess.run(
                [
                    "docker",
                    "exec",
                    "-d",
                    container_name,
                    "sh",
                    "-lc",
                    f"exec muxlyd --transport unsafe+tcp://0.0.0.0:{REMOTE_TCP_PORT} >/tmp/muxlyd.stdout 2>/tmp/muxlyd.stderr",
                ],
                cwd=REPO,
                env=env,
                check=True,
            )

            tcp_transport = f"tcp://{host_tcp_ip}:{host_tcp_port}"
            ping = wait_for_tcp_ping(env, tcp_transport, require_unsafe_flag=True)
            assert ping["result"]["pong"] is True

            tcp_without_override = subprocess.run(
                [
                    str(REPO / "zig-out/bin/muxly"),
                    "--transport",
                    tcp_transport,
                    "ping",
                ],
                cwd=REPO,
                env=env,
                text=True,
                capture_output=True,
            )
            assert tcp_without_override.returncode != 0

            capabilities = run_cli(
                env,
                "--transport",
                tcp_transport,
                UNSAFE_TCP_FLAG,
                "capabilities",
                "get",
            )["result"]
            assert capabilities["supportsTcpSocket"] is True
            assert "tcp" in capabilities["implementedTransports"]

            ssh_transport = f"ssh://{SSH_USER}@127.0.0.1:{ssh_port}/tcp://127.0.0.1:{REMOTE_TCP_PORT}"
            ssh_ping = run_cli(env, "--transport", ssh_transport, "ping")
            assert ssh_ping["result"]["pong"] is True

            relay_responses = run_transport_relay(
                env,
                ssh_transport,
                [
                    {"jsonrpc": "2.0", "id": 1, "method": "ping", "params": {}},
                    {"jsonrpc": "2.0", "id": 2, "method": "initialize", "params": {}},
                ],
            )
            assert len(relay_responses) == 2
            assert relay_responses[0]["result"]["pong"] is True
            assert relay_responses[1]["result"]["supportsTcpSocket"] is True

        finally:
            if container_id:
                subprocess.run(
                    ["docker", "rm", "-f", container_name],
                    cwd=REPO,
                    env=env,
                    check=False,
                    stdout=subprocess.DEVNULL,
                    stderr=subprocess.DEVNULL,
                )


if __name__ == "__main__":
    main()

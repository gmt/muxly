import argparse
import json
import os
import pathlib
import select
import signal
import socket
import subprocess
import tempfile
import time
import uuid
from dataclasses import dataclass
from datetime import datetime

try:
    from reportlab.lib.pagesizes import letter
    from reportlab.lib.styles import getSampleStyleSheet
    from reportlab.lib.units import inch
    from reportlab.platypus import Paragraph, SimpleDocTemplate, Spacer

    HAVE_REPORTLAB = True
except ImportError:  # pragma: no cover - optional dependency
    HAVE_REPORTLAB = False


REPO = pathlib.Path(__file__).resolve().parents[2]
MUXLY = REPO / "zig-out/bin/muxly"
MUXLYD = REPO / "zig-out/bin/muxlyd"
DEFAULT_PROBE = REPO / "zig-out/bin/muxly-fit-probe"
LISTENING_PREFIX = "muxlyd listening on "
NETEM_IMAGE_TAG = "muxly/h2-operational-fit-netem:local"
UNSAFE_TCP_FLAG = "--i-know-this-is-unencrypted-and-unauthenticated"


@dataclass
class DaemonInstance:
    process: subprocess.Popen[str]
    actual_spec: str
    identity_dir: pathlib.Path | None


@dataclass
class ProxyInstance:
    name: str
    mode: str
    container_name: str
    transport_spec: str


@dataclass
class MixedLoadFixture:
    session_name: str
    node_id: int


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


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Run HTTP/2 operational-fit decision support.")
    parser.add_argument(
        "--skip-build",
        action="store_true",
        help="assume zig-out binaries and the probe already exist",
    )
    parser.add_argument(
        "--output-dir",
        help="directory for reports; defaults under /tmp/decision_support",
    )
    return parser.parse_args()


def run_checked(*args: str, env: dict[str, str] | None = None, timeout: int = 120) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        list(args),
        cwd=REPO,
        env=env,
        text=True,
        check=True,
        capture_output=True,
        timeout=timeout,
    )


def run_cli(env: dict[str, str], *args: str) -> dict:
    completed = run_checked(str(MUXLY), *args, env=env)
    return json.loads(completed.stdout)


def run_transport_relay(env: dict[str, str], transport_spec: str, requests: list[dict]) -> list[dict]:
    payload = "\n".join(json.dumps(request) for request in requests) + "\n"
    completed = subprocess.run(
        [str(MUXLY), "--transport", transport_spec, "transport", "relay"],
        cwd=REPO,
        env=env,
        text=True,
        input=payload,
        capture_output=True,
        check=True,
        timeout=60,
    )
    return [json.loads(line) for line in completed.stdout.splitlines() if line.strip()]


def build_binaries(probe_path: pathlib.Path) -> None:
    subprocess.run(
        ["zig", "build", "muxly", "muxlyd", "muxly-fit-probe"],
        cwd=REPO,
        check=True,
    )
    if not probe_path.exists():
        raise AssertionError(f"missing operational-fit probe at {probe_path}")


def build_netem_image() -> None:
    subprocess.run(
        [
            "docker",
            "build",
            "-t",
            NETEM_IMAGE_TAG,
            str(REPO / "tests/integration/h2_operational_fit/netem_proxy"),
        ],
        cwd=REPO,
        check=True,
    )


def read_listening_spec(proc: subprocess.Popen[str], timeout: float = 120.0) -> str:
    assert proc.stderr is not None
    fd = proc.stderr.fileno()
    os.set_blocking(fd, False)
    deadline = time.time() + timeout
    buffered = ""

    while time.time() < deadline:
        if proc.poll() is not None:
            raise AssertionError(
                f"daemon exited early with code {proc.returncode}: {buffered}{proc.stderr.read()}"
            )

        ready, _, _ = select.select([fd], [], [], 0.2)
        if not ready:
            continue

        chunk = os.read(fd, 4096).decode()
        if not chunk:
            continue
        buffered += chunk

        while "\n" in buffered:
            line, buffered = buffered.split("\n", 1)
            line = line.strip()
            if line.startswith(LISTENING_PREFIX):
                return line[len(LISTENING_PREFIX) :]

    raise AssertionError(f"timed out waiting for daemon readiness; stderr so far: {buffered}")


def start_daemon(transport_spec: str, extra_env: dict[str, str] | None = None) -> DaemonInstance:
    env = os.environ.copy()
    env["MUXLY_ENABLE_DEBUG_RPC"] = "1"
    identity_dir: pathlib.Path | None = None
    if transport_spec.startswith("h3wt://"):
        identity_dir = pathlib.Path(tempfile.mkdtemp(prefix="muxly-h3wt-identity-"))
        env["MUXLY_H3WT_IDENTITY_DIR"] = str(identity_dir)
    if extra_env:
        env.update(extra_env)

    proc = subprocess.Popen(
        [str(MUXLYD), "--transport", transport_spec],
        cwd=REPO,
        env=env,
        text=True,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.PIPE,
    )
    try:
        actual_spec = read_listening_spec(proc)
        return DaemonInstance(process=proc, actual_spec=actual_spec, identity_dir=identity_dir)
    except BaseException:
        stop_process(proc)
        if identity_dir:
            try:
                identity_dir.rmdir()
            except OSError:
                pass
        raise


def stop_process(proc: subprocess.Popen[str]) -> None:
    if proc.poll() is not None:
        return
    proc.terminate()
    try:
        proc.wait(timeout=5)
        return
    except subprocess.TimeoutExpired:
        pass
    proc.kill()
    proc.wait(timeout=5)


def stop_daemon(instance: DaemonInstance) -> None:
    stop_process(instance.process)
    if instance.identity_dir:
        for child in instance.identity_dir.iterdir():
            child.unlink(missing_ok=True)
        instance.identity_dir.rmdir()


def parse_http_like_transport(transport_spec: str) -> tuple[str, int, str]:
    scheme, rest = transport_spec.split("://", 1)
    host_port, path = rest.split("/", 1)
    host, port_text = host_port.rsplit(":", 1)
    return scheme, int(port_text), "/" + path


def normalize_client_spec(transport_spec: str) -> str:
    scheme, port, path = parse_http_like_transport(transport_spec)
    if scheme.startswith("unsafe+"):
        scheme = scheme[len("unsafe+") :]
    return f"{scheme}://127.0.0.1:{port}{path}"


def parse_docker_port_host_port(output: str) -> int:
    for line in output.splitlines():
        endpoint = line.strip()
        if endpoint.startswith("0.0.0.0:") or endpoint.startswith("127.0.0.1:"):
            return int(endpoint.rsplit(":", 1)[1])
    first = output.splitlines()[0].strip()
    return int(first.rsplit(":", 1)[1])


def wait_for_ping(env: dict[str, str], transport_spec: str, timeout: float = 20.0) -> None:
    deadline = time.time() + timeout
    last_error: Exception | None = None
    while time.time() < deadline:
        try:
            ping = run_cli(env, "--transport", transport_spec, "ping")
            if ping["result"]["pong"] is True:
                return
        except Exception as exc:  # noqa: BLE001
            last_error = exc
            time.sleep(0.25)
    raise AssertionError(f"timed out waiting for ping on {transport_spec!r}: {last_error!r}")


def ensure_documents(env: dict[str, str], transport_spec: str) -> None:
    requests = [
        {"jsonrpc": "2.0", "id": 1, "method": "document.create", "params": {"path": "/a"}},
        {"jsonrpc": "2.0", "id": 2, "method": "document.create", "params": {"path": "/b"}},
    ]
    responses = run_transport_relay(env, transport_spec, requests)
    for response in responses:
        if "error" in response:
            message = response["error"]["message"]
            if "already exists" in message:
                continue
            raise AssertionError(f"unable to create validation documents: {response}")


def create_tmux_session_node(env: dict[str, str], transport_spec: str, session_name: str, command: str) -> int:
    response = run_cli(
        env,
        "--transport",
        transport_spec,
        "session",
        "create",
        session_name,
        command,
    )
    return int(response["result"]["nodeId"])


def mixed_load_command(prefix: str) -> str:
    return (
        "sh -lc 'i=0; while [ \"$i\" -lt 6000 ]; do "
        f"printf \"{prefix}-%04d zzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzz\\n\" \"$i\"; "
        "i=$((i+1)); "
        "if [ $((i % 50)) -eq 0 ]; then sleep 0.01; fi; "
        "done; sleep 30'"
    )


def create_mixed_load_fixture(
    env: dict[str, str],
    transport_spec: str,
    session_prefix: str,
    output_prefix: str,
) -> MixedLoadFixture:
    session_name = f"{session_prefix}-{uuid.uuid4().hex[:8]}"
    node_id = create_tmux_session_node(env, transport_spec, session_name, mixed_load_command(output_prefix))
    return MixedLoadFixture(session_name=session_name, node_id=node_id)


def cleanup_mixed_load_fixture(fixture: MixedLoadFixture | None) -> None:
    if fixture is not None:
        cleanup_tmux_session(fixture.session_name)


def cleanup_tmux_session(session_name: str) -> None:
    subprocess.run(
        ["tmux", "kill-session", "-t", session_name],
        cwd=REPO,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
        check=False,
    )


def tmux_available() -> bool:
    try:
        subprocess.run(
            ["tmux", "-V"],
            cwd=REPO,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            check=True,
        )
    except Exception:  # noqa: BLE001
        return False
    return True


def write_template(src: pathlib.Path, dst: pathlib.Path, replacements: dict[str, str]) -> None:
    text = src.read_text()
    for key, value in replacements.items():
        text = text.replace(key, value)
    dst.write_text(text)


def start_proxy_container(
    proxy_name: str,
    temp_dir: pathlib.Path,
    daemon_transport_spec: str,
    upstream_host: str,
) -> ProxyInstance:
    _, upstream_port, path = parse_http_like_transport(daemon_transport_spec)
    container_name = f"muxly-h2-fit-{proxy_name}-{uuid.uuid4().hex[:10]}"

    if proxy_name == "caddy":
        config_path = temp_dir / "Caddyfile"
        write_template(
            REPO / "tests/integration/h2_operational_fit/caddy/Caddyfile.template",
            config_path,
            {
                "__UPSTREAM_HOST__": upstream_host,
                "__UPSTREAM_PORT__": str(upstream_port),
            },
        )
        subprocess.run(
            [
                "docker",
                "run",
                "-d",
                "--rm",
                "--name",
                container_name,
                "-v",
                f"{config_path}:/etc/caddy/Caddyfile:ro",
                "-p",
                "127.0.0.1::8080",
                "caddy:2-alpine",
            ],
            cwd=REPO,
            check=True,
            stdout=subprocess.DEVNULL,
        )
        mode = "reverse-proxy-h2c"
    elif proxy_name == "haproxy":
        config_path = temp_dir / "haproxy.cfg"
        write_template(
            REPO / "tests/integration/h2_operational_fit/haproxy/haproxy.cfg.template",
            config_path,
            {
                "__UPSTREAM_HOST__": upstream_host,
                "__UPSTREAM_PORT__": str(upstream_port),
            },
        )
        subprocess.run(
            [
                "docker",
                "run",
                "-d",
                "--rm",
                "--name",
                container_name,
                "-v",
                f"{config_path}:/usr/local/etc/haproxy/haproxy.cfg:ro",
                "-p",
                "127.0.0.1::8080",
                "haproxy:3.0-alpine",
            ],
            cwd=REPO,
            check=True,
            stdout=subprocess.DEVNULL,
        )
        mode = "tcp-pass-through"
    elif proxy_name == "nginx":
        config_path = temp_dir / "nginx.conf"
        write_template(
            REPO / "tests/integration/h2_operational_fit/nginx/nginx.conf.template",
            config_path,
            {
                "__UPSTREAM_HOST__": upstream_host,
                "__UPSTREAM_PORT__": str(upstream_port),
            },
        )
        subprocess.run(
            [
                "docker",
                "run",
                "-d",
                "--rm",
                "--name",
                container_name,
                "-v",
                f"{config_path}:/etc/nginx/nginx.conf:ro",
                "-p",
                "127.0.0.1::8080",
                "nginx:1.27-alpine",
            ],
            cwd=REPO,
            check=True,
            stdout=subprocess.DEVNULL,
        )
        mode = "tcp-pass-through"
    else:
        raise AssertionError(f"unknown proxy {proxy_name}")

    port_output = run_checked("docker", "port", container_name, "8080/tcp").stdout.strip()
    host_port = parse_docker_port_host_port(port_output)
    client_scheme = daemon_transport_spec.split("://", 1)[0]
    if client_scheme.startswith("unsafe+"):
        client_scheme = client_scheme[len("unsafe+") :]
    return ProxyInstance(
        name=proxy_name,
        mode=mode,
        container_name=container_name,
        transport_spec=f"{client_scheme}://127.0.0.1:{host_port}{path}",
    )


def stop_proxy_container(proxy: ProxyInstance) -> None:
    subprocess.run(
        ["docker", "rm", "-f", proxy.container_name],
        cwd=REPO,
        check=False,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
    )


def start_netem_proxy(
    temp_dir: pathlib.Path,
    transport_spec: str,
    upstream_host: str,
    delay_ms: int,
    loss_pct: float,
) -> ProxyInstance:
    scheme, upstream_port, path = parse_http_like_transport(transport_spec)
    container_name = f"muxly-h2-fit-netem-{uuid.uuid4().hex[:10]}"
    subprocess.run(
        [
            "docker",
            "run",
            "-d",
            "--rm",
            "--name",
            container_name,
            "--cap-add",
            "NET_ADMIN",
            "-e",
            f"UPSTREAM_HOST={upstream_host}",
            "-e",
            f"UPSTREAM_PORT={upstream_port}",
            "-e",
            f"DELAY_MS={delay_ms}",
            "-e",
            f"LOSS_PCT={loss_pct}",
            "-p",
            "127.0.0.1::8080",
            NETEM_IMAGE_TAG,
        ],
        cwd=REPO,
        check=True,
        stdout=subprocess.DEVNULL,
    )
    port_output = run_checked("docker", "port", container_name, "8080/tcp").stdout.strip()
    host_port = parse_docker_port_host_port(port_output)
    client_scheme = scheme[len("unsafe+") :] if scheme.startswith("unsafe+") else scheme
    return ProxyInstance(
        name="netem",
        mode=f"netem delay={delay_ms}ms loss={loss_pct}%",
        container_name=container_name,
        transport_spec=f"{client_scheme}://127.0.0.1:{host_port}{path}",
    )


def run_probe(probe_path: pathlib.Path, subcommand: str, *args: str) -> dict:
    completed = subprocess.run(
        [str(probe_path), subcommand, *args],
        cwd=REPO,
        text=True,
        capture_output=True,
        timeout=60,
    )
    if completed.returncode != 0:
        raise AssertionError(
            f"probe {subcommand!r} failed with code {completed.returncode}: "
            f"stdout={completed.stdout!r} stderr={completed.stderr!r}"
        )
    return json.loads(completed.stdout)


def capture_error(exc: Exception) -> dict:
    return {"error": repr(exc)}


def summarize_report_error(value: object) -> str:
    text = str(value)
    first_line = text.splitlines()[0].strip()
    return first_line or "n/a"


def report_has_mixed_load_errors(proxy_results: list[dict], comparison_results: list[dict]) -> bool:
    for item in proxy_results:
        mixed = item.get("scenarios", {}).get("mixedLoad", {})
        if "error" in mixed:
            return True
    for item in comparison_results:
        for transport_key in ("http", "h2"):
            mixed = item.get(transport_key, {}).get("mixedLoad", {})
            if "error" in mixed:
                return True
    return False


def maybe_run(fn, *args, **kwargs) -> dict:
    try:
        value = fn(*args, **kwargs)
        return {"ok": True} if value is None else value
    except Exception as exc:  # noqa: BLE001
        return capture_error(exc)


def run_proxy_bundle(
    env: dict[str, str],
    probe_path: pathlib.Path,
    transport_spec: str,
    mixed_node_id: int | None,
) -> dict:
    result: dict[str, object] = {}
    result["ping"] = maybe_run(run_cli, env, "--transport", transport_spec, "ping")
    result["documentStatus"] = maybe_run(run_cli, env, "--transport", transport_spec, "document", "status")
    result["sleepOverlap"] = maybe_run(
        run_probe,
        probe_path,
        "sleep-overlap",
        "--transport",
        transport_spec,
        "--slow-doc",
        "/a",
        "--fast-doc",
        "/b",
        "--slow-ms",
        "320",
        "--fast-ms",
        "120",
    )
    if mixed_node_id is None:
        result["mixedLoad"] = {"skipped": True, "reason": "tmux unavailable"}
    else:
        result["mixedLoad"] = maybe_run(
            run_probe,
            probe_path,
            "mixed-load",
            "--transport",
            transport_spec,
            "--node-id",
            str(mixed_node_id),
            "--rpc-count",
            "24",
        )
    return result


def run_proxy_matrix(env: dict[str, str], probe_path: pathlib.Path, output_dir: pathlib.Path) -> list[dict]:
    host_ipv4 = select_non_loopback_host_ipv4()
    daemon = start_daemon("unsafe+h2://0.0.0.0:0/rpc")
    direct_spec = normalize_client_spec(daemon.actual_spec)
    ensure_documents(env, direct_spec)

    mixed_node_id: int | None = None
    session_name: str | None = None
    if tmux_available():
        fixture = create_mixed_load_fixture(env, direct_spec, "muxly-fit", "fit")
        session_name = fixture.session_name
        mixed_node_id = fixture.node_id

    results: list[dict] = []
    try:
        wait_for_ping(env, direct_spec)
        results.append(
            {
                "name": "direct",
                "mode": "control",
                "transportSpec": direct_spec,
                "scenarios": run_proxy_bundle(env, probe_path, direct_spec, mixed_node_id),
            }
        )

        for proxy_name in ("caddy", "haproxy", "nginx"):
            with tempfile.TemporaryDirectory(prefix=f"muxly-{proxy_name}-") as temp_dir_str:
                proxy = start_proxy_container(proxy_name, pathlib.Path(temp_dir_str), daemon.actual_spec, host_ipv4)
                try:
                    wait_for_ping(env, proxy.transport_spec)
                    results.append(
                        {
                            "name": proxy.name,
                            "mode": proxy.mode,
                            "transportSpec": proxy.transport_spec,
                            "scenarios": run_proxy_bundle(env, probe_path, proxy.transport_spec, mixed_node_id),
                        }
                    )
                except Exception as exc:  # noqa: BLE001
                    results.append(
                        {
                            "name": proxy.name,
                            "mode": proxy.mode,
                            "transportSpec": proxy.transport_spec,
                            "error": repr(exc),
                        }
                    )
                finally:
                    stop_proxy_container(proxy)
    finally:
        if session_name:
            cleanup_tmux_session(session_name)
        stop_daemon(daemon)

    return results


def run_comparison_matrix(env: dict[str, str], probe_path: pathlib.Path) -> list[dict]:
    host_ipv4 = select_non_loopback_host_ipv4()
    tmux_enabled = tmux_available()

    profiles = [
        {"name": "baseline", "delayMs": 0, "lossPct": 0.0},
        {"name": "delay-75ms", "delayMs": 75, "lossPct": 0.0},
        {"name": "loss-1pct", "delayMs": 0, "lossPct": 1.0},
        {"name": "delay-75ms-loss-1pct", "delayMs": 75, "lossPct": 1.0},
    ]

    results: list[dict] = []
    for profile in profiles:
        http_daemon = start_daemon("unsafe+http://0.0.0.0:0/rpc")
        h2_daemon = start_daemon("unsafe+h2://0.0.0.0:0/rpc")
        http_direct_spec = normalize_client_spec(http_daemon.actual_spec)
        h2_direct_spec = normalize_client_spec(h2_daemon.actual_spec)
        http_proxy: ProxyInstance | None = None
        h2_proxy: ProxyInstance | None = None
        http_fixture: MixedLoadFixture | None = None
        h2_fixture: MixedLoadFixture | None = None
        try:
            ensure_documents(env, http_direct_spec)
            ensure_documents(env, h2_direct_spec)

            http_proxy: ProxyInstance | None = None
            h2_proxy: ProxyInstance | None = None
            if profile["delayMs"] == 0 and profile["lossPct"] == 0.0:
                http_spec = http_direct_spec
                h2_spec = h2_direct_spec
            else:
                http_proxy = start_netem_proxy(
                    pathlib.Path(tempfile.mkdtemp(prefix="muxly-http-netem-")),
                    http_daemon.actual_spec,
                    host_ipv4,
                    profile["delayMs"],
                    profile["lossPct"],
                )
                h2_proxy = start_netem_proxy(
                    pathlib.Path(tempfile.mkdtemp(prefix="muxly-h2-netem-")),
                    h2_daemon.actual_spec,
                    host_ipv4,
                    profile["delayMs"],
                    profile["lossPct"],
                )
                http_spec = http_proxy.transport_spec
                h2_spec = h2_proxy.transport_spec

            if tmux_enabled:
                wait_for_ping(env, http_direct_spec)
                wait_for_ping(env, h2_direct_spec)
                http_fixture = create_mixed_load_fixture(env, http_direct_spec, "muxly-http-fit", "cmp-http")
                h2_fixture = create_mixed_load_fixture(env, h2_direct_spec, "muxly-h2-fit", "cmp-h2")

            profile_result = {
                "profile": profile,
                "http": {},
                "h2": {},
            }
            profile_result["http"]["reachability"] = maybe_run(wait_for_ping, env, http_spec)
            profile_result["h2"]["reachability"] = maybe_run(wait_for_ping, env, h2_spec)

            if "error" not in profile_result["http"]["reachability"]:
                profile_result["http"]["pingLoop"] = maybe_run(
                    run_probe,
                    probe_path,
                    "ping-loop",
                    "--transport",
                    http_spec,
                    "--count",
                    "24",
                )
                profile_result["http"]["sleepOverlap"] = maybe_run(
                    run_probe,
                    probe_path,
                    "sleep-overlap",
                    "--transport",
                    http_spec,
                    "--slow-doc",
                    "/a",
                    "--fast-doc",
                    "/b",
                    "--slow-ms",
                    "320",
                    "--fast-ms",
                    "120",
                )
                profile_result["http"]["reconnectLoop"] = maybe_run(
                    run_probe,
                    probe_path,
                    "reconnect-loop",
                    "--transport",
                    http_spec,
                    "--count",
                    "8",
                )
            else:
                profile_result["http"]["pingLoop"] = {"skipped": True, "reason": "unreachable"}
                profile_result["http"]["sleepOverlap"] = {"skipped": True, "reason": "unreachable"}
                profile_result["http"]["reconnectLoop"] = {"skipped": True, "reason": "unreachable"}

            if "error" not in profile_result["h2"]["reachability"]:
                profile_result["h2"]["pingLoop"] = maybe_run(
                    run_probe,
                    probe_path,
                    "ping-loop",
                    "--transport",
                    h2_spec,
                    "--count",
                    "24",
                )
                profile_result["h2"]["sleepOverlap"] = maybe_run(
                    run_probe,
                    probe_path,
                    "sleep-overlap",
                    "--transport",
                    h2_spec,
                    "--slow-doc",
                    "/a",
                    "--fast-doc",
                    "/b",
                    "--slow-ms",
                    "320",
                    "--fast-ms",
                    "120",
                )
                profile_result["h2"]["reconnectLoop"] = maybe_run(
                    run_probe,
                    probe_path,
                    "reconnect-loop",
                    "--transport",
                    h2_spec,
                    "--count",
                    "8",
                )
            else:
                profile_result["h2"]["pingLoop"] = {"skipped": True, "reason": "unreachable"}
                profile_result["h2"]["sleepOverlap"] = {"skipped": True, "reason": "unreachable"}
                profile_result["h2"]["reconnectLoop"] = {"skipped": True, "reason": "unreachable"}

            if http_fixture is None or h2_fixture is None:
                profile_result["http"]["mixedLoad"] = {"skipped": True, "reason": "tmux unavailable"}
                profile_result["h2"]["mixedLoad"] = {"skipped": True, "reason": "tmux unavailable"}
            else:
                profile_result["http"]["mixedLoad"] = (
                    maybe_run(
                        run_probe,
                        probe_path,
                        "mixed-load",
                        "--transport",
                        http_spec,
                        "--node-id",
                        str(http_fixture.node_id),
                        "--rpc-count",
                        "24",
                    )
                    if "error" not in profile_result["http"]["reachability"]
                    else {"skipped": True, "reason": "unreachable"}
                )
                profile_result["h2"]["mixedLoad"] = (
                    maybe_run(
                        run_probe,
                        probe_path,
                        "mixed-load",
                        "--transport",
                        h2_spec,
                        "--node-id",
                        str(h2_fixture.node_id),
                        "--rpc-count",
                        "24",
                    )
                    if "error" not in profile_result["h2"]["reachability"]
                    else {"skipped": True, "reason": "unreachable"}
                )
            results.append(profile_result)
        finally:
            had_fixture = http_fixture is not None or h2_fixture is not None
            cleanup_mixed_load_fixture(http_fixture)
            cleanup_mixed_load_fixture(h2_fixture)
            if had_fixture:
                time.sleep(0.2)
            if http_proxy is not None:
                stop_proxy_container(http_proxy)
            if h2_proxy is not None:
                stop_proxy_container(h2_proxy)
            stop_daemon(http_daemon)
            stop_daemon(h2_daemon)

    return results


def summarize_recommendation(proxy_results: list[dict], comparison_results: list[dict]) -> str:
    if report_has_mixed_load_errors(proxy_results, comparison_results):
        return "needs-human-call"
    proxy_successes = sum(1 for item in proxy_results if item.get("name") != "direct" and "error" not in item)
    h2_better_profiles = 0
    comparable_profiles = 0
    for item in comparison_results:
        http_mixed = item["http"].get("mixedLoad", {})
        h2_mixed = item["h2"].get("mixedLoad", {})
        if "ping" not in http_mixed or "ping" not in h2_mixed:
            continue
        comparable_profiles += 1
        if h2_mixed["ping"]["p95Ms"] < http_mixed["ping"]["p95Ms"]:
            h2_better_profiles += 1

    if proxy_successes >= 1 and h2_better_profiles >= max(1, comparable_profiles // 2):
        return "keep-h2-for-now"
    if proxy_successes == 0:
        return "gut-h2-candidate"
    return "needs-human-call"


def render_markdown(report: dict) -> str:
    lines = [
        "# H2 Operational Fit Report",
        "",
        f"Generated: {report['generatedAt']}",
        f"Repo head: {report['head']}",
        f"Recommendation: {report['recommendation']}",
        "",
        "## Proxy matrix",
        "",
        "| topology | mode | result | notes |",
        "| --- | --- | --- | --- |",
    ]
    for item in report["proxyMatrix"]:
        if "error" in item:
            lines.append(f"| {item['name']} | {item['mode']} | fail | `{item['error']}` |")
        else:
            lines.append(f"| {item['name']} | {item['mode']} | pass | `{item['transportSpec']}` |")

    lines.extend(["", "## H1 vs H2 comparison", ""])
    for item in report["comparisons"]:
        lines.append(f"### {item['profile']['name']}")
        lines.append("")
        http_ping = item["http"].get("pingLoop", {})
        h2_ping = item["h2"].get("pingLoop", {})
        if "stats" in http_ping and "stats" in h2_ping:
            lines.append(
                f"- HTTP ping p95: {http_ping['stats']['p95Ms']} ms; "
                f"H2 ping p95: {h2_ping['stats']['p95Ms']} ms"
            )
        else:
            lines.append(
                f"- Ping loop errors: HTTP `{summarize_report_error(http_ping.get('error', http_ping.get('reason', 'n/a')))}`; "
                f"H2 `{summarize_report_error(h2_ping.get('error', h2_ping.get('reason', 'n/a')))}`"
            )

        http_reconnect = item["http"].get("reconnectLoop", {})
        h2_reconnect = item["h2"].get("reconnectLoop", {})
        if "stats" in http_reconnect and "stats" in h2_reconnect:
            lines.append(
                f"- HTTP reconnect max: {http_reconnect['stats']['maxMs']} ms; "
                f"H2 reconnect max: {h2_reconnect['stats']['maxMs']} ms"
            )
        else:
            lines.append(
                f"- Reconnect errors: HTTP `{summarize_report_error(http_reconnect.get('error', http_reconnect.get('reason', 'n/a')))}`; "
                f"H2 `{summarize_report_error(h2_reconnect.get('error', h2_reconnect.get('reason', 'n/a')))}`"
            )
        http_mixed = item['http'].get('mixedLoad', {})
        h2_mixed = item['h2'].get('mixedLoad', {})
        if 'ping' in http_mixed and 'ping' in h2_mixed:
            lines.append(
                f"- Mixed-load ping p95: HTTP {http_mixed['ping']['p95Ms']} ms vs H2 {h2_mixed['ping']['p95Ms']} ms"
            )
            lines.append(
                f"- Mixed-load mode: HTTP {http_mixed['mode']} vs H2 {h2_mixed['mode']}"
            )
        else:
            lines.append(
                f"- Mixed-load notes: HTTP `{summarize_report_error(http_mixed.get('error', http_mixed.get('reason', 'n/a')))}`; "
                f"H2 `{summarize_report_error(h2_mixed.get('error', h2_mixed.get('reason', 'n/a')))}`"
            )
        lines.append("")

    return "\n".join(lines) + "\n"


def render_pdf(report: dict, output_dir: pathlib.Path) -> pathlib.Path | None:
    if not HAVE_REPORTLAB:
        return None

    pdf_path = output_dir / "report.pdf"
    styles = getSampleStyleSheet()
    styles["Title"].fontSize = 18
    styles["Heading1"].fontSize = 14
    styles["BodyText"].fontSize = 9.5
    styles["BodyText"].leading = 12

    story = [
        Paragraph("H2 Operational Fit Report", styles["Title"]),
        Spacer(1, 0.15 * inch),
        Paragraph(f"Generated: {report['generatedAt']}", styles["BodyText"]),
        Paragraph(f"Repo head: {report['head']}", styles["BodyText"]),
        Paragraph(f"Recommendation: {report['recommendation']}", styles["BodyText"]),
        Spacer(1, 0.15 * inch),
        Paragraph("Proxy matrix", styles["Heading1"]),
    ]

    for item in report["proxyMatrix"]:
        if "error" in item:
            line = f"- {item['name']} ({item['mode']}): fail - {summarize_report_error(item['error'])}"
        else:
            line = f"- {item['name']} ({item['mode']}): pass - {item['transportSpec']}"
        story.append(Paragraph(line, styles["BodyText"]))

    story.append(Spacer(1, 0.15 * inch))
    story.append(Paragraph("H1 vs H2 comparison", styles["Heading1"]))
    for item in report["comparisons"]:
        story.append(Paragraph(item["profile"]["name"], styles["Heading1"]))
        http_ping = item["http"].get("pingLoop", {})
        h2_ping = item["h2"].get("pingLoop", {})
        if "stats" in http_ping and "stats" in h2_ping:
            story.append(
                Paragraph(
                    f"HTTP ping p95: {http_ping['stats']['p95Ms']} ms; H2 ping p95: {h2_ping['stats']['p95Ms']} ms",
                    styles["BodyText"],
                )
            )
        else:
            story.append(
                Paragraph(
                    f"Ping notes: HTTP {summarize_report_error(http_ping.get('error', http_ping.get('reason', 'n/a')))}; "
                    f"H2 {summarize_report_error(h2_ping.get('error', h2_ping.get('reason', 'n/a')))}",
                    styles["BodyText"],
                )
            )
        http_mixed = item["http"].get("mixedLoad", {})
        h2_mixed = item["h2"].get("mixedLoad", {})
        if "ping" in http_mixed and "ping" in h2_mixed:
            story.append(
                Paragraph(
                    f"Mixed-load ping p95: HTTP {http_mixed['ping']['p95Ms']} ms vs H2 {h2_mixed['ping']['p95Ms']} ms",
                    styles["BodyText"],
                )
            )
        else:
            story.append(
                Paragraph(
                    f"Mixed-load notes: HTTP {summarize_report_error(http_mixed.get('error', http_mixed.get('reason', 'n/a')))}; "
                    f"H2 {summarize_report_error(h2_mixed.get('error', h2_mixed.get('reason', 'n/a')))}",
                    styles["BodyText"],
                )
            )
        story.append(Spacer(1, 0.08 * inch))

    doc = SimpleDocTemplate(
        str(pdf_path),
        pagesize=letter,
        leftMargin=0.6 * inch,
        rightMargin=0.6 * inch,
        topMargin=0.6 * inch,
        bottomMargin=0.6 * inch,
    )
    doc.build(story)
    return pdf_path


def main() -> None:
    args = parse_args()

    output_dir = (
        pathlib.Path(args.output_dir)
        if args.output_dir
        else pathlib.Path("/tmp/decision_support") / f"h2_operational_fit-{datetime.now().strftime('%Y%m%d-%H%M%S')}"
    )
    output_dir.mkdir(parents=True, exist_ok=True)

    probe_path = pathlib.Path(os.environ.get("MUXLY_FIT_PROBE", str(DEFAULT_PROBE)))

    if not args.skip_build:
        build_binaries(probe_path)
    build_netem_image()

    env = os.environ.copy()

    proxy_results = run_proxy_matrix(env, probe_path, output_dir)
    comparison_results = run_comparison_matrix(env, probe_path)

    report = {
        "generatedAt": datetime.now().isoformat(timespec="seconds"),
        "head": run_checked("git", "rev-parse", "--short", "HEAD").stdout.strip(),
        "proxyMatrix": proxy_results,
        "comparisons": comparison_results,
    }
    report["recommendation"] = summarize_recommendation(proxy_results, comparison_results)

    report_path = output_dir / "report.json"
    report_path.write_text(json.dumps(report, indent=2))
    markdown_path = output_dir / "report.md"
    markdown_path.write_text(render_markdown(report))
    pdf_path = render_pdf(report, output_dir)

    payload = {
        "outputDir": str(output_dir),
        "report": str(report_path),
        "markdown": str(markdown_path),
        "recommendation": report["recommendation"],
    }
    if pdf_path is not None:
        payload["pdf"] = str(pdf_path)
    print(json.dumps(payload))


if __name__ == "__main__":
    main()

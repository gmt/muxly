from dataclasses import dataclass
import hashlib
import json
import os
import pathlib
import select
import subprocess
import time

import pytest


REPO = pathlib.Path(__file__).resolve().parents[2]
MUXLY = REPO / "zig-out/bin/muxly"
MUXLYD = REPO / "zig-out/bin/muxlyd"
LISTENING_PREFIX = "muxlyd listening on "
TRANSPORT_MATRIX = (
    pytest.param("http://127.0.0.1:0/rpc", id="http"),
    pytest.param("h2://127.0.0.1:0/rpc", id="h2"),
    pytest.param("h3wt://127.0.0.1:0/mux", id="h3wt"),
)


@dataclass(frozen=True)
class TransportCase:
    cwd: pathlib.Path
    env: dict[str, str]
    requested_transport: str
    actual_transport: str


def run_cli(case: TransportCase, *args: str) -> dict:
    completed = subprocess.run(
        [str(MUXLY), *args],
        cwd=case.cwd,
        env=case.env,
        text=True,
        capture_output=True,
        check=True,
        timeout=20,
    )
    return json.loads(completed.stdout)


def run_transport_relay(case: TransportCase, requests: list[dict]) -> list[dict]:
    payload = "\n".join(json.dumps(request) for request in requests) + "\n"
    completed = subprocess.run(
        [str(MUXLY), "--transport", case.actual_transport, "transport", "relay"],
        cwd=case.cwd,
        env=case.env,
        text=True,
        input=payload,
        capture_output=True,
        check=True,
        timeout=20,
    )
    return [json.loads(line) for line in completed.stdout.splitlines() if line.strip()]


def transport_to_absolute_trd(transport_spec: str, selector: str) -> str:
    if transport_spec.startswith("http://"):
        endpoint = transport_spec[len("http://") :]
        return f"trd://ht1|{endpoint}::/#{selector}"
    if transport_spec.startswith("h2://"):
        endpoint = transport_spec[len("h2://") :]
        return f"trd://ht2|{endpoint}::/#{selector}"
    if transport_spec.startswith("h3wt://"):
        endpoint = transport_spec[len("h3wt://") :]
        return f"trd://wtp|{endpoint}::/#{selector}"
    raise AssertionError(f"unexpected transport spec {transport_spec!r}")


def transport_to_absolute_document_trd(transport_spec: str, document_path: str) -> str:
    normalized = document_path if document_path.startswith("/") else f"/{document_path}"
    if normalized == "/":
        doc_suffix = "/"
    else:
        doc_suffix = normalized

    if transport_spec.startswith("http://"):
        endpoint = transport_spec[len("http://") :]
        return f"trd://ht1|{endpoint}::{doc_suffix}"
    if transport_spec.startswith("h2://"):
        endpoint = transport_spec[len("h2://") :]
        return f"trd://ht2|{endpoint}::{doc_suffix}"
    if transport_spec.startswith("h3wt://"):
        endpoint = transport_spec[len("h3wt://") :]
        return f"trd://wtp|{endpoint}::{doc_suffix}"
    raise AssertionError(f"unexpected transport spec {transport_spec!r}")


def transport_to_composite_document_trd(transport_spec: str, document_path: str) -> str:
    normalized = document_path if document_path.startswith("/") else f"/{document_path}"
    if normalized == "/":
        return f"trd://{transport_endpoint(transport_spec)}"
    return f"trd://{transport_endpoint(transport_spec)}::{normalized}"


def transport_to_htp_document_trd(transport_spec: str, document_path: str) -> str:
    normalized = document_path if document_path.startswith("/") else f"/{document_path}"
    if normalized == "/":
        return f"trd://htp|{transport_endpoint(transport_spec)}"
    return f"trd://htp|{transport_endpoint(transport_spec)}::{normalized}"


def transport_endpoint(transport_spec: str) -> str:
    if transport_spec.startswith("http://"):
        return transport_spec[len("http://") :]
    if transport_spec.startswith("h2://"):
        return transport_spec[len("h2://") :]
    if transport_spec.startswith("h3wt://"):
        return transport_spec[len("h3wt://") :]
    raise AssertionError(f"unexpected transport spec {transport_spec!r}")


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


def start_daemon(
    cwd: pathlib.Path,
    env: dict[str, str],
    transport_spec: str,
) -> tuple[subprocess.Popen[str], str]:
    proc = subprocess.Popen(
        [str(MUXLYD), "--transport", transport_spec],
        cwd=cwd,
        env=env,
        text=True,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.PIPE,
    )
    try:
        actual_spec = read_listening_spec(proc)
        return proc, actual_spec
    except BaseException:
        stop_process(proc)
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


def unique_name(request: pytest.FixtureRequest, prefix: str) -> str:
    slug = hashlib.sha1(request.node.nodeid.encode("utf-8")).hexdigest()[:8]
    return f"{prefix}-{slug}"


def check_ping_and_document(case: TransportCase) -> None:
    ping = run_cli(case, "--transport", case.actual_transport, "ping")
    assert ping["result"]["pong"] is True

    document = run_cli(case, "--transport", case.actual_transport, "document", "get")
    assert document["result"]["rootNodeId"] == 1
    assert len(document["result"]["nodes"]) >= 2


def check_trd_resolution(case: TransportCase) -> None:
    relative = run_cli(case, "--transport", case.actual_transport, "node", "get", "trd:#welcome")
    assert relative["result"]["title"] == "welcome"

    absolute_trd = transport_to_absolute_trd(case.actual_transport, "welcome")
    absolute = run_cli(case, "node", "get", absolute_trd)
    assert absolute["result"]["title"] == "welcome"


def check_session_reuse(case: TransportCase) -> None:
    responses = run_transport_relay(
        case,
        [
            {"jsonrpc": "2.0", "id": 1, "method": "ping", "params": {}},
            {"jsonrpc": "2.0", "id": 2, "method": "document.status", "params": {}},
        ],
    )
    assert responses[0]["result"]["pong"] is True
    assert responses[1]["result"]["rootNodeId"] == 1


def check_document_target_handling(case: TransportCase) -> None:
    responses = run_transport_relay(
        case,
        [
            {
                "jsonrpc": "2.0",
                "id": 1,
                "target": {"documentPath": "/"},
                "method": "document.status",
                "params": {},
            },
            {
                "jsonrpc": "2.0",
                "id": 2,
                "target": {"documentPath": "/not-yet"},
                "method": "document.status",
                "params": {},
            },
        ],
    )
    assert responses[0]["result"]["rootNodeId"] == 1
    assert responses[1]["error"]["code"] == -32001
    assert "not supported yet" in responses[1]["error"]["message"]


def check_document_catalog_and_scoping(
    case: TransportCase,
    request: pytest.FixtureRequest,
) -> None:
    slug = unique_name(request, "scoped")
    document_path = f"/demo/{slug}"
    attached_file = case.cwd / f"{slug}.txt"
    session_name = f"{slug}-session"
    attached_file.write_text("scoped file content\n", encoding="utf-8")

    responses = run_transport_relay(
        case,
        [
            {
                "jsonrpc": "2.0",
                "id": 1,
                "method": "document.create",
                "params": {"path": document_path},
            },
            {
                "jsonrpc": "2.0",
                "id": 2,
                "method": "document.list",
                "params": {},
            },
            {
                "jsonrpc": "2.0",
                "id": 3,
                "target": {"documentPath": document_path},
                "method": "leaf.source.attach",
                "params": {"kind": "static-file", "path": str(attached_file)},
            },
            {
                "jsonrpc": "2.0",
                "id": 4,
                "target": {"documentPath": document_path},
                "method": "file.capture",
                "params": {"nodeId": 2},
            },
            {
                "jsonrpc": "2.0",
                "id": 5,
                "target": {"documentPath": document_path},
                "method": "document.get",
                "params": {},
            },
            {
                "jsonrpc": "2.0",
                "id": 6,
                "target": {"documentPath": "/"},
                "method": "document.get",
                "params": {},
            },
            {
                "jsonrpc": "2.0",
                "id": 7,
                "target": {"documentPath": document_path},
                "method": "session.create",
                "params": {"sessionName": session_name},
            },
        ],
    )

    assert responses[0]["result"]["path"] == document_path
    listed_paths = [entry["path"] for entry in responses[1]["result"]]
    assert "/" in listed_paths
    assert document_path in listed_paths
    assert responses[2]["result"]["nodeId"] == 2
    assert responses[3]["result"]["content"] == "scoped file content\n"

    demo_titles = [node["title"] for node in responses[4]["result"]["nodes"]]
    assert str(attached_file) in demo_titles
    root_titles = [node["title"] for node in responses[5]["result"]["nodes"]]
    assert str(attached_file) not in root_titles

    assert responses[6]["error"]["code"] == -32001
    assert "root document target /" in responses[6]["error"]["message"]


def check_node_target_shape(
    case: TransportCase,
    request: pytest.FixtureRequest,
) -> None:
    node_title = unique_name(request, "node")
    created = run_transport_relay(
        case,
        [
            {
                "jsonrpc": "2.0",
                "id": 1,
                "method": "node.append",
                "params": {"parentId": 1, "kind": "scroll_region", "title": node_title},
            },
        ],
    )

    node_id = created[0]["result"]["nodeId"]

    responses = run_transport_relay(
        case,
        [
            {
                "jsonrpc": "2.0",
                "id": 2,
                "target": {"documentPath": "/", "nodeId": node_id},
                "method": "node.get",
                "params": {},
            },
            {
                "jsonrpc": "2.0",
                "id": 3,
                "target": {"documentPath": "/", "selector": node_title},
                "method": "node.get",
                "params": {},
            },
            {
                "jsonrpc": "2.0",
                "id": 4,
                "target": {"documentPath": "/", "selector": "does-not-exist"},
                "method": "node.get",
                "params": {},
            },
        ],
    )

    assert responses[0]["result"]["id"] == node_id
    assert responses[0]["result"]["title"] == node_title
    assert responses[1]["result"]["id"] == node_id
    assert responses[1]["result"]["title"] == node_title
    assert responses[2]["error"]["code"] == -32602
    assert "does not match any node" in responses[2]["error"]["message"]


def check_cli_trd_target_modes(
    case: TransportCase,
    request: pytest.FixtureRequest,
) -> None:
    slug = unique_name(request, "doc")
    document_path = f"/docs/{slug}"
    doc_root_child_title = f"{slug}-doc-root-child"
    selector_child_title = f"{slug}-welcome-child"

    run_transport_relay(
        case,
        [
            {
                "jsonrpc": "2.0",
                "id": 1,
                "method": "document.create",
                "params": {"path": document_path},
            },
        ],
    )

    doc_trd = transport_to_absolute_document_trd(case.actual_transport, document_path)
    composite_doc_trd = transport_to_composite_document_trd(case.actual_transport, document_path)
    root_node = run_cli(case, "--transport", case.actual_transport, "node", "get", doc_trd)
    assert root_node["result"]["kind"] == "document"
    assert root_node["result"]["title"] == slug

    composite_root_node = run_cli(
        case,
        "--transport",
        case.actual_transport,
        "node",
        "get",
        composite_doc_trd,
    )
    assert composite_root_node["result"]["kind"] == "document"
    assert composite_root_node["result"]["title"] == slug

    if case.actual_transport.startswith("http://") or case.actual_transport.startswith("h2://"):
        htp_doc_trd = transport_to_htp_document_trd(case.actual_transport, document_path)
        htp_root_node = run_cli(
            case,
            "--transport",
            case.actual_transport,
            "node",
            "get",
            htp_doc_trd,
        )
        assert htp_root_node["result"]["kind"] == "document"
        assert htp_root_node["result"]["title"] == slug

    appended_under_root = run_cli(
        case,
        "--transport",
        case.actual_transport,
        "node",
        "append",
        doc_trd,
        "scroll_region",
        doc_root_child_title,
    )
    assert appended_under_root["result"]["kind"] == "scroll_region"

    appended_under_selector = run_cli(
        case,
        "--transport",
        case.actual_transport,
        "node",
        "append",
        "trd:#welcome",
        "scroll_region",
        selector_child_title,
    )
    assert appended_under_selector["result"]["kind"] == "scroll_region"

    appended_doc = run_transport_relay(
        case,
        [
            {
                "jsonrpc": "2.0",
                "id": 2,
                "target": {"documentPath": document_path},
                "method": "document.get",
                "params": {},
            },
        ],
    )[0]
    appended_titles = [node["title"] for node in appended_doc["result"]["nodes"]]
    assert doc_root_child_title in appended_titles

    selector_child = run_cli(
        case,
        "--transport",
        case.actual_transport,
        "node",
        "get",
        f"trd:#welcome/{selector_child_title}",
    )
    assert selector_child["result"]["title"] == selector_child_title


def transport_id(transport_spec: str) -> str:
    if transport_spec.startswith("http://"):
        return "http"
    if transport_spec.startswith("h2://"):
        return "h2"
    if transport_spec.startswith("h3wt://"):
        return "h3wt"
    raise AssertionError(f"unexpected transport spec {transport_spec!r}")


@pytest.fixture(params=TRANSPORT_MATRIX)
def transport_case(
    request: pytest.FixtureRequest,
    tmp_path: pathlib.Path,
) -> TransportCase:
    requested_transport = request.param
    temp_dir = tmp_path
    env = os.environ.copy()
    env["MUXLY_H3WT_IDENTITY_DIR"] = str(temp_dir / "identity")

    proc, actual_transport = start_daemon(temp_dir, env, requested_transport)
    try:
        yield TransportCase(
            cwd=temp_dir,
            env=env,
            requested_transport=requested_transport,
            actual_transport=actual_transport,
        )
    finally:
        stop_process(proc)


def test_ping_and_document(transport_case: TransportCase) -> None:
    check_ping_and_document(transport_case)


def test_trd_resolution(transport_case: TransportCase) -> None:
    check_trd_resolution(transport_case)


def test_session_reuse(transport_case: TransportCase) -> None:
    check_session_reuse(transport_case)


def test_document_target_handling(transport_case: TransportCase) -> None:
    check_document_target_handling(transport_case)


def test_document_catalog_and_scoping(
    transport_case: TransportCase,
    request: pytest.FixtureRequest,
) -> None:
    check_document_catalog_and_scoping(transport_case, request)


def test_node_target_shape(
    transport_case: TransportCase,
    request: pytest.FixtureRequest,
) -> None:
    check_node_target_shape(transport_case, request)


def test_cli_trd_target_modes(
    transport_case: TransportCase,
    request: pytest.FixtureRequest,
) -> None:
    check_cli_trd_target_modes(transport_case, request)

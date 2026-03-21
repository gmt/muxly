import argparse
import json
import os
import pathlib
import select
import signal
import subprocess
import tempfile
import time


REPO = pathlib.Path(__file__).resolve().parents[2]
MUXLY = REPO / "zig-out/bin/muxly"
MUXLYD = REPO / "zig-out/bin/muxlyd"
LISTENING_PREFIX = "muxlyd listening on "


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Run HTTP and H3WT transport integration coverage."
    )
    parser.add_argument(
        "--skip-build",
        action="store_true",
        help="assume zig-out/bin/muxly and zig-out/bin/muxlyd already exist",
    )
    return parser.parse_args()


def build_binaries() -> None:
    subprocess.run(["zig", "build", "muxly", "muxlyd"], cwd=REPO, check=True)


def run_cli(cwd: pathlib.Path, env: dict[str, str], *args: str) -> dict:
    completed = subprocess.run(
        [str(MUXLY), *args],
        cwd=cwd,
        env=env,
        text=True,
        capture_output=True,
        check=True,
        timeout=20,
    )
    return json.loads(completed.stdout)


def run_transport_relay(
    cwd: pathlib.Path,
    env: dict[str, str],
    transport_spec: str,
    requests: list[dict],
) -> list[dict]:
    payload = "\n".join(json.dumps(request) for request in requests) + "\n"
    completed = subprocess.run(
        [str(MUXLY), "--transport", transport_spec, "transport", "relay"],
        cwd=cwd,
        env=env,
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
        return f"trd://http|{endpoint}//#{selector}"
    if transport_spec.startswith("h3wt://"):
        endpoint = transport_spec[len("h3wt://") :]
        return f"trd://wt|{endpoint}//#{selector}"
    raise AssertionError(f"unexpected transport spec {transport_spec!r}")


def transport_to_absolute_document_trd(transport_spec: str, document_path: str) -> str:
    normalized = document_path if document_path.startswith("/") else f"/{document_path}"
    if normalized == "/":
        doc_suffix = ""
    else:
        doc_suffix = normalized[1:]

    if transport_spec.startswith("http://"):
        endpoint = transport_spec[len("http://") :]
        return f"trd://http|{endpoint}//{doc_suffix}"
    if transport_spec.startswith("h3wt://"):
        endpoint = transport_spec[len("h3wt://") :]
        return f"trd://wt|{endpoint}//{doc_suffix}"
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


def assert_ping_and_document(cwd: pathlib.Path, env: dict[str, str], transport_spec: str) -> None:
    ping = run_cli(cwd, env, "--transport", transport_spec, "ping")
    assert ping["result"]["pong"] is True

    document = run_cli(cwd, env, "--transport", transport_spec, "document", "get")
    assert document["result"]["rootNodeId"] == 1
    assert len(document["result"]["nodes"]) >= 2


def assert_trd_resolution(cwd: pathlib.Path, env: dict[str, str], transport_spec: str) -> None:
    relative = run_cli(cwd, env, "--transport", transport_spec, "node", "get", "trd:#welcome")
    assert relative["result"]["title"] == "welcome"

    absolute_trd = transport_to_absolute_trd(transport_spec, "welcome")
    absolute = run_cli(cwd, env, "node", "get", absolute_trd)
    assert absolute["result"]["title"] == "welcome"


def assert_session_reuse(cwd: pathlib.Path, env: dict[str, str], transport_spec: str) -> None:
    responses = run_transport_relay(
        cwd,
        env,
        transport_spec,
        [
            {"jsonrpc": "2.0", "id": 1, "method": "ping", "params": {}},
            {"jsonrpc": "2.0", "id": 2, "method": "document.status", "params": {}},
        ],
    )
    assert responses[0]["result"]["pong"] is True
    assert responses[1]["result"]["rootNodeId"] == 1


def assert_document_target_handling(
    cwd: pathlib.Path, env: dict[str, str], transport_spec: str
) -> None:
    responses = run_transport_relay(
        cwd,
        env,
        transport_spec,
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


def assert_document_catalog_and_scoping(
    cwd: pathlib.Path, env: dict[str, str], transport_spec: str
) -> None:
    attached_file = cwd / "scoped-demo.txt"
    attached_file.write_text("scoped file content\n", encoding="utf-8")

    responses = run_transport_relay(
        cwd,
        env,
        transport_spec,
        [
            {
                "jsonrpc": "2.0",
                "id": 1,
                "method": "document.create",
                "params": {"path": "/demo/doc"},
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
                "target": {"documentPath": "/demo/doc"},
                "method": "leaf.source.attach",
                "params": {"kind": "static-file", "path": str(attached_file)},
            },
            {
                "jsonrpc": "2.0",
                "id": 4,
                "target": {"documentPath": "/demo/doc"},
                "method": "file.capture",
                "params": {"nodeId": 2},
            },
            {
                "jsonrpc": "2.0",
                "id": 5,
                "target": {"documentPath": "/demo/doc"},
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
                "target": {"documentPath": "/demo/doc"},
                "method": "session.create",
                "params": {"sessionName": "should-not-cross"},
            },
        ],
    )

    assert responses[0]["result"]["path"] == "/demo/doc"
    listed_paths = [entry["path"] for entry in responses[1]["result"]]
    assert "/" in listed_paths
    assert "/demo/doc" in listed_paths
    assert responses[2]["result"]["nodeId"] == 2
    assert responses[3]["result"]["content"] == "scoped file content\n"

    demo_titles = [node["title"] for node in responses[4]["result"]["nodes"]]
    assert str(attached_file) in demo_titles
    root_titles = [node["title"] for node in responses[5]["result"]["nodes"]]
    assert str(attached_file) not in root_titles

    assert responses[6]["error"]["code"] == -32001
    assert "root document target /" in responses[6]["error"]["message"]


def assert_node_target_shape(
    cwd: pathlib.Path, env: dict[str, str], transport_spec: str
) -> None:
    created = run_transport_relay(
        cwd,
        env,
        transport_spec,
        [
            {
                "jsonrpc": "2.0",
                "id": 1,
                "method": "node.append",
                "params": {"parentId": 1, "kind": "scroll_region", "title": "node-target-demo"},
            },
        ],
    )

    node_id = created[0]["result"]["nodeId"]

    responses = run_transport_relay(
        cwd,
        env,
        transport_spec,
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
                "target": {"documentPath": "/", "selector": "node-target-demo"},
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
    assert responses[0]["result"]["title"] == "node-target-demo"
    assert responses[1]["result"]["id"] == node_id
    assert responses[1]["result"]["title"] == "node-target-demo"
    assert responses[2]["error"]["code"] == -32602
    assert "does not match any node" in responses[2]["error"]["message"]


def assert_cli_trd_target_modes(
    cwd: pathlib.Path, env: dict[str, str], transport_spec: str
) -> None:
    run_transport_relay(
        cwd,
        env,
        transport_spec,
        [
            {
                "jsonrpc": "2.0",
                "id": 1,
                "method": "document.create",
                "params": {"path": "/docs/demo"},
            },
        ],
    )

    doc_trd = transport_to_absolute_document_trd(transport_spec, "/docs/demo")
    root_node = run_cli(cwd, env, "--transport", transport_spec, "node", "get", doc_trd)
    assert root_node["result"]["kind"] == "document"
    assert root_node["result"]["title"] == "demo"

    appended_under_root = run_cli(
        cwd,
        env,
        "--transport",
        transport_spec,
        "node",
        "append",
        doc_trd,
        "scroll_region",
        "doc-root-child",
    )
    assert appended_under_root["result"]["kind"] == "scroll_region"

    appended_under_selector = run_cli(
        cwd,
        env,
        "--transport",
        transport_spec,
        "node",
        "append",
        "trd:#welcome",
        "scroll_region",
        "welcome-child",
    )
    assert appended_under_selector["result"]["kind"] == "scroll_region"

    appended_doc = run_transport_relay(
        cwd,
        env,
        transport_spec,
        [
            {
                "jsonrpc": "2.0",
                "id": 2,
                "target": {"documentPath": "/docs/demo"},
                "method": "document.get",
                "params": {},
            },
        ],
    )[0]
    appended_titles = [node["title"] for node in appended_doc["result"]["nodes"]]
    assert "doc-root-child" in appended_titles

    selector_child = run_cli(cwd, env, "--transport", transport_spec, "node", "get", "trd:#welcome/welcome-child")
    assert selector_child["result"]["title"] == "welcome-child"


def exercise_transport(
    cwd: pathlib.Path,
    env: dict[str, str],
    requested_transport: str,
) -> None:
    proc, actual_transport = start_daemon(cwd, env, requested_transport)
    try:
        assert_ping_and_document(cwd, env, actual_transport)
        assert_trd_resolution(cwd, env, actual_transport)
        assert_session_reuse(cwd, env, actual_transport)
        assert_document_target_handling(cwd, env, actual_transport)
        assert_document_catalog_and_scoping(cwd, env, actual_transport)
        assert_node_target_shape(cwd, env, actual_transport)
        assert_cli_trd_target_modes(cwd, env, actual_transport)
    finally:
        stop_process(proc)


def main() -> None:
    args = parse_args()
    if not args.skip_build:
        build_binaries()

    with tempfile.TemporaryDirectory(prefix="muxly-http-h3wt-") as temp_dir_str:
        temp_dir = pathlib.Path(temp_dir_str)
        env = os.environ.copy()
        env["MUXLY_H3WT_IDENTITY_DIR"] = str(temp_dir / "identity")

        exercise_transport(temp_dir, env, "http://127.0.0.1:0/rpc")
        exercise_transport(temp_dir, env, "h3wt://127.0.0.1:0/mux")


if __name__ == "__main__":
    main()

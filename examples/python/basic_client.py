import ctypes
import os
import time


def main() -> None:
    lib = ctypes.CDLL("./zig-out/lib/libmuxly.so")
    lib.muxly_version.restype = ctypes.c_char_p
    lib.muxly_client_create.argtypes = [ctypes.c_char_p]
    lib.muxly_client_create.restype = ctypes.c_void_p
    lib.muxly_client_destroy.argtypes = [ctypes.c_void_p]
    lib.muxly_client_ping.argtypes = [ctypes.c_void_p]
    lib.muxly_client_ping.restype = ctypes.c_void_p
    lib.muxly_client_document_status.argtypes = [ctypes.c_void_p]
    lib.muxly_client_document_status.restype = ctypes.c_void_p
    lib.muxly_client_document_get.argtypes = [ctypes.c_void_p]
    lib.muxly_client_document_get.restype = ctypes.c_void_p
    lib.muxly_client_session_create.argtypes = [ctypes.c_void_p, ctypes.c_char_p, ctypes.c_char_p]
    lib.muxly_client_session_create.restype = ctypes.c_void_p
    lib.muxly_client_graph_get.argtypes = [ctypes.c_void_p]
    lib.muxly_client_graph_get.restype = ctypes.c_void_p
    lib.muxly_string_free.argtypes = [ctypes.c_void_p]

    socket_path = os.environ.get("MUXLY_SOCKET", "/tmp/muxly.sock").encode()
    session_name = f"muxly-python-example-{os.getpid()}".encode()
    command = b"sh -lc 'printf hello-from-python-binding\\n; sleep 1'"

    print("muxly version:", lib.muxly_version().decode())
    print("socket path:", socket_path.decode())
    client = lib.muxly_client_create(socket_path)
    if not client:
        raise SystemExit("client create failed")

    ptr = lib.muxly_client_ping(client)
    if not ptr:
        raise SystemExit("ping failed")

    try:
        print("ping response:", ctypes.cast(ptr, ctypes.c_char_p).value.decode())
    finally:
        lib.muxly_string_free(ptr)

    status_ptr = lib.muxly_client_document_status(client)
    if not status_ptr:
        raise SystemExit("document status failed")

    try:
        print("document status:", ctypes.cast(status_ptr, ctypes.c_char_p).value.decode())
    finally:
        lib.muxly_string_free(status_ptr)

    session_ptr = lib.muxly_client_session_create(client, session_name, command)
    if not session_ptr:
        raise SystemExit("session create failed")
    try:
        print("session create response:", ctypes.cast(session_ptr, ctypes.c_char_p).value.decode())
    finally:
        lib.muxly_string_free(session_ptr)

    time.sleep(0.2)

    document_ptr = lib.muxly_client_document_get(client)
    if not document_ptr:
        raise SystemExit("document get failed")
    try:
        print("document response:", ctypes.cast(document_ptr, ctypes.c_char_p).value.decode())
    finally:
        lib.muxly_string_free(document_ptr)

    graph_ptr = lib.muxly_client_graph_get(client)
    if not graph_ptr:
        raise SystemExit("graph get failed")
    try:
        print("graph response:", ctypes.cast(graph_ptr, ctypes.c_char_p).value.decode())
    finally:
        lib.muxly_string_free(graph_ptr)

    lib.muxly_client_destroy(client)


if __name__ == "__main__":
    main()

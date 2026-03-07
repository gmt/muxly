import ctypes


def main() -> None:
    lib = ctypes.CDLL("./zig-out/lib/libmuxly.so")
    lib.muxly_version.restype = ctypes.c_char_p
    lib.muxly_client_create.argtypes = [ctypes.c_char_p]
    lib.muxly_client_create.restype = ctypes.c_void_p
    lib.muxly_client_destroy.argtypes = [ctypes.c_void_p]
    lib.muxly_client_ping.argtypes = [ctypes.c_void_p]
    lib.muxly_client_ping.restype = ctypes.c_void_p
    lib.muxly_client_document_get.argtypes = [ctypes.c_void_p]
    lib.muxly_client_document_get.restype = ctypes.c_void_p
    lib.muxly_client_node_get.argtypes = [ctypes.c_void_p, ctypes.c_ulonglong]
    lib.muxly_client_node_get.restype = ctypes.c_void_p
    lib.muxly_client_view_set_root.argtypes = [ctypes.c_void_p, ctypes.c_ulonglong]
    lib.muxly_client_view_set_root.restype = ctypes.c_void_p
    lib.muxly_client_graph_get.argtypes = [ctypes.c_void_p]
    lib.muxly_client_graph_get.restype = ctypes.c_void_p
    lib.muxly_string_free.argtypes = [ctypes.c_void_p]

    print("muxly version:", lib.muxly_version().decode())
    client = lib.muxly_client_create(b"/tmp/muxly.sock")
    if not client:
        raise SystemExit("client create failed")

    ptr = lib.muxly_client_ping(client)
    if not ptr:
        raise SystemExit("ping failed")

    try:
        print("ping response:", ctypes.cast(ptr, ctypes.c_char_p).value.decode())
    finally:
        lib.muxly_string_free(ptr)

    document_ptr = lib.muxly_client_document_get(client)
    if not document_ptr:
        raise SystemExit("document get failed")

    try:
        print("document response:", ctypes.cast(document_ptr, ctypes.c_char_p).value.decode())
    finally:
        lib.muxly_string_free(document_ptr)

    node_ptr = lib.muxly_client_node_get(client, 2)
    if not node_ptr:
        raise SystemExit("node get failed")
    try:
        print("node response:", ctypes.cast(node_ptr, ctypes.c_char_p).value.decode())
    finally:
        lib.muxly_string_free(node_ptr)

    root_ptr = lib.muxly_client_view_set_root(client, 2)
    if not root_ptr:
        raise SystemExit("view set root failed")
    try:
        print("view set root response:", ctypes.cast(root_ptr, ctypes.c_char_p).value.decode())
    finally:
        lib.muxly_string_free(root_ptr)

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

import ctypes
import json
import os


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
    lib.muxly_client_node_append.argtypes = [ctypes.c_void_p, ctypes.c_ulonglong, ctypes.c_char_p, ctypes.c_char_p]
    lib.muxly_client_node_append.restype = ctypes.c_void_p
    lib.muxly_client_node_update.argtypes = [ctypes.c_void_p, ctypes.c_ulonglong, ctypes.c_char_p, ctypes.c_char_p]
    lib.muxly_client_node_update.restype = ctypes.c_void_p
    lib.muxly_client_node_get.argtypes = [ctypes.c_void_p, ctypes.c_ulonglong]
    lib.muxly_client_node_get.restype = ctypes.c_void_p
    lib.muxly_client_node_remove.argtypes = [ctypes.c_void_p, ctypes.c_ulonglong]
    lib.muxly_client_node_remove.restype = ctypes.c_void_p
    lib.muxly_client_view_clear_root.argtypes = [ctypes.c_void_p]
    lib.muxly_client_view_clear_root.restype = ctypes.c_void_p
    lib.muxly_client_view_set_root.argtypes = [ctypes.c_void_p, ctypes.c_ulonglong]
    lib.muxly_client_view_set_root.restype = ctypes.c_void_p
    lib.muxly_client_view_elide.argtypes = [ctypes.c_void_p, ctypes.c_ulonglong]
    lib.muxly_client_view_elide.restype = ctypes.c_void_p
    lib.muxly_client_view_expand.argtypes = [ctypes.c_void_p, ctypes.c_ulonglong]
    lib.muxly_client_view_expand.restype = ctypes.c_void_p
    lib.muxly_client_view_reset.argtypes = [ctypes.c_void_p]
    lib.muxly_client_view_reset.restype = ctypes.c_void_p
    lib.muxly_client_graph_get.argtypes = [ctypes.c_void_p]
    lib.muxly_client_graph_get.restype = ctypes.c_void_p
    lib.muxly_string_free.argtypes = [ctypes.c_void_p]

    socket_path = os.environ.get("MUXLY_SOCKET", "/tmp/muxly.sock").encode()

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

    append_ptr = lib.muxly_client_node_append(client, 1, b"subdocument", b"python c abi scaffold")
    if not append_ptr:
        raise SystemExit("node append failed")
    try:
        append_response = ctypes.cast(append_ptr, ctypes.c_char_p).value.decode()
        print("node append response:", append_response)
    finally:
        lib.muxly_string_free(append_ptr)

    node_id = json.loads(append_response)["result"]["nodeId"]

    update_ptr = lib.muxly_client_node_update(client, node_id, None, b"hello synthetic api from python")
    if not update_ptr:
        raise SystemExit("node update failed")
    try:
        print("node update response:", ctypes.cast(update_ptr, ctypes.c_char_p).value.decode())
    finally:
        lib.muxly_string_free(update_ptr)

    node_ptr = lib.muxly_client_node_get(client, node_id)
    if not node_ptr:
        raise SystemExit("node get failed")
    try:
        print("node response:", ctypes.cast(node_ptr, ctypes.c_char_p).value.decode())
    finally:
        lib.muxly_string_free(node_ptr)

    set_root_ptr = lib.muxly_client_view_set_root(client, node_id)
    if not set_root_ptr:
        raise SystemExit("view set root failed")
    try:
        print("view set root response:", ctypes.cast(set_root_ptr, ctypes.c_char_p).value.decode())
    finally:
        lib.muxly_string_free(set_root_ptr)

    elide_ptr = lib.muxly_client_view_elide(client, node_id)
    if not elide_ptr:
        raise SystemExit("view elide failed")
    try:
        print("view elide response:", ctypes.cast(elide_ptr, ctypes.c_char_p).value.decode())
    finally:
        lib.muxly_string_free(elide_ptr)

    expand_ptr = lib.muxly_client_view_expand(client, node_id)
    if not expand_ptr:
        raise SystemExit("view expand failed")
    try:
        print("view expand response:", ctypes.cast(expand_ptr, ctypes.c_char_p).value.decode())
    finally:
        lib.muxly_string_free(expand_ptr)

    clear_root_ptr = lib.muxly_client_view_clear_root(client)
    if not clear_root_ptr:
        raise SystemExit("view clear root failed")
    try:
        print("view clear root response:", ctypes.cast(clear_root_ptr, ctypes.c_char_p).value.decode())
    finally:
        lib.muxly_string_free(clear_root_ptr)

    reset_ptr = lib.muxly_client_view_reset(client)
    if not reset_ptr:
        raise SystemExit("view reset failed")
    try:
        print("view reset response:", ctypes.cast(reset_ptr, ctypes.c_char_p).value.decode())
    finally:
        lib.muxly_string_free(reset_ptr)

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

    remove_ptr = lib.muxly_client_node_remove(client, node_id)
    if not remove_ptr:
        raise SystemExit("node remove failed")
    try:
        print("node remove response:", ctypes.cast(remove_ptr, ctypes.c_char_p).value.decode())
    finally:
        lib.muxly_string_free(remove_ptr)

    lib.muxly_client_destroy(client)


if __name__ == "__main__":
    main()

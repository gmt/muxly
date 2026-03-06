import ctypes


def main() -> None:
    lib = ctypes.CDLL("./zig-out/lib/libmuxly.so")
    lib.muxly_version.restype = ctypes.c_char_p
    lib.muxly_ping.argtypes = [ctypes.c_char_p]
    lib.muxly_ping.restype = ctypes.c_void_p
    lib.muxly_document_get.argtypes = [ctypes.c_char_p]
    lib.muxly_document_get.restype = ctypes.c_void_p
    lib.muxly_string_free.argtypes = [ctypes.c_void_p]

    print("muxly version:", lib.muxly_version().decode())
    ptr = lib.muxly_ping(b"/tmp/muxly.sock")
    if not ptr:
        raise SystemExit("ping failed")

    try:
        print("ping response:", ctypes.cast(ptr, ctypes.c_char_p).value.decode())
    finally:
        lib.muxly_string_free(ptr)

    document_ptr = lib.muxly_document_get(b"/tmp/muxly.sock")
    if not document_ptr:
        raise SystemExit("document get failed")

    try:
        print("document response:", ctypes.cast(document_ptr, ctypes.c_char_p).value.decode())
    finally:
        lib.muxly_string_free(document_ptr)


if __name__ == "__main__":
    main()

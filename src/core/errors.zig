pub const RpcErrorCode = enum(i32) {
    parse_error = -32700,
    invalid_request = -32600,
    method_not_found = -32601,
    invalid_params = -32602,
    internal_error = -32603,
    unsupported = -32001,
    backend_unavailable = -32002,
    transport_error = -32003,
    source_error = -32004,
};

/**
 * @file muxly.h
 * Public C / FFI header for libmuxly.
 */
#ifndef MUXLY_H
#define MUXLY_H

#ifdef __cplusplus
extern "C" {
#endif

/**
 * Opaque client handle. Create with muxly_client_create() and destroy with
 * muxly_client_destroy().
 */
typedef struct muxly_client muxly_client;

/**
 * @brief Status code returned by the structured C / FFI entry points.
 */
typedef enum muxly_status {
    /** The call produced an output value successfully. */
    MUXLY_STATUS_OK = 0,
    /** A required pointer argument was NULL. */
    MUXLY_STATUS_NULL_ARGUMENT = 1,
    /** The request was rejected before transport, such as invalid arguments. */
    MUXLY_STATUS_INVALID_ARGUMENT = 2,
    /** The current platform transport is not implemented. */
    MUXLY_STATUS_UNSUPPORTED_PLATFORM = 3,
    /** Allocation failed inside libmuxly. */
    MUXLY_STATUS_ALLOCATION_FAILURE = 4,
    /** A request failed before an output value could be returned. */
    MUXLY_STATUS_TRANSPORT_FAILURE = 5,
} muxly_status;

/**
 * @brief Version string for the shared library.
 *
 * The returned pointer is static storage owned by libmuxly. Do not free it.
 */
const char *muxly_version(void);

/**
 * @brief Returns a stable string name for one muxly_status value.
 *
 * The returned pointer is static storage owned by libmuxly. Do not free it.
 *
 * @param status Status code to format.
 * @return Static string for the supplied status.
 */
const char *muxly_status_string(muxly_status status);

/**
 * @name Stateless convenience helpers
 *
 * Stateless convenience helpers.
 *
 * `socket_path` must be a non-null NUL-terminated string.
 * On success these functions return a heap-allocated UTF-8 JSON-RPC response
 * payload that must be released with muxly_string_free().
 * A non-NULL return may still contain a JSON-RPC error payload from the
 * daemon; callers must inspect the envelope.
 * On failure before a response string can be returned, they return NULL.
 * @{
 */
char *muxly_ping(const char *socket_path);
char *muxly_document_get(const char *socket_path);
char *muxly_graph_get(const char *socket_path);
/** @} */

/**
 * @name Handle-based client lifecycle
 *
 * Handle-based client lifecycle.
 *
 * `socket_path` must be a non-null NUL-terminated string.
 * Handles are not thread-safe; do not use one client concurrently from
 * multiple threads without external synchronization.
 * The handle stores a copied socket path, not a persistent daemon connection.
 * muxly_client_create() returns NULL on allocation failure.
 * Destroying a NULL client is allowed.
 * @{
 */
/**
 * @brief Create a handle bound to one daemon socket path.
 *
 * @param socket_path NUL-terminated daemon socket path to copy into the handle.
 * @return A new handle on success, or NULL if allocation or socket-path copy
 * fails.
 */
muxly_client *muxly_client_create(const char *socket_path);

/**
 * @brief Structured variant of muxly_client_create().
 *
 * New bindings should prefer the `_ex` family because it distinguishes
 * library-side failure categories without overloading `NULL`.
 *
 * @param socket_path NUL-terminated daemon socket path to copy into the handle.
 * @param out_client Output pointer that receives a new handle on success.
 * @return `MUXLY_STATUS_OK` on success, otherwise a status describing why the
 * handle could not be created. On failure, `*out_client` is set to NULL.
 */
muxly_status muxly_client_create_ex(const char *socket_path, muxly_client **out_client);

/**
 * @brief Destroy a client handle created by muxly_client_create().
 *
 * Passing NULL is allowed. The handle must not be used again after this call.
 *
 * @param client Handle to destroy, or NULL.
 */
void muxly_client_destroy(muxly_client *client);
/** @} */

/**
 * @name Handle-based request helpers
 *
 * Handle-based request helpers.
 *
 * Unless otherwise noted, `client` and any string arguments must be non-null.
 * On success each function returns a heap-allocated UTF-8 JSON-RPC response
 * payload that must be released with muxly_string_free().
 * A non-NULL return may still contain a JSON-RPC error payload from the
 * daemon; callers must inspect the envelope.
 * On failure before a response string can be returned, they return NULL.
 * @{
 */
char *muxly_client_ping(muxly_client *client);
char *muxly_client_document_get(muxly_client *client);
char *muxly_client_graph_get(muxly_client *client);
char *muxly_client_document_status(muxly_client *client);
/** @} */

/**
 * @name Synthetic document-editing helpers
 *
 * Synthetic document-editing helpers.
 *
 * node ids are muxly node ids from earlier response payloads.
 * muxly_client_node_append() requires non-null `kind` and `title`.
 * muxly_client_node_update() requires at least one of `title` or `content`;
 * either pointer may be NULL as long as the other is non-null.
 * muxly_client_node_freeze() currently supports tty-backed nodes only and
 * requires a non-null artifact kind string such as "text" or "surface".
 * @{
 */
char *muxly_client_node_append(
    muxly_client *client,
    unsigned long long parent_id,
    const char *kind,
    const char *title
);
/**
 * @brief Update one node title or content.
 *
 * Exactly one of `title` or `content` should normally be provided. Either may
 * be NULL as long as the other is non-null. If both are NULL, libmuxly fails
 * before sending a request and returns NULL.
 *
 * @param client Handle created by muxly_client_create().
 * @param node_id muxly node id to update.
 * @param title Optional replacement title, or NULL.
 * @param content Optional replacement content, or NULL.
 * @return Heap-allocated JSON-RPC response payload on transport success, or
 * NULL if libmuxly fails before returning a response string.
 */
char *muxly_client_node_update(
    muxly_client *client,
    unsigned long long node_id,
    const char *title,
    const char *content
);
char *muxly_client_node_freeze(
    muxly_client *client,
    unsigned long long node_id,
    const char *artifact_kind
);
char *muxly_client_node_remove(muxly_client *client, unsigned long long node_id);
/** @} */

/**
 * @name Node and view helpers
 *
 * Node/view helpers use muxly node ids from earlier response payloads.
 * @{
 */
char *muxly_client_node_get(muxly_client *client, unsigned long long node_id);
char *muxly_client_leaf_source_get(muxly_client *client, unsigned long long node_id);
char *muxly_client_view_clear_root(muxly_client *client);
char *muxly_client_view_set_root(muxly_client *client, unsigned long long node_id);
char *muxly_client_view_elide(muxly_client *client, unsigned long long node_id);
char *muxly_client_view_expand(muxly_client *client, unsigned long long node_id);
char *muxly_client_view_reset(muxly_client *client);
/** @} */

/**
 * @name tmux helpers
 *
 * tmux helpers accept muxly pane ids, targets, or session names as
 * NUL-terminated strings.
 *
 * `command` may be NULL for muxly_client_pane_split() and
 * muxly_client_session_create().
 * @{
 */
char *muxly_client_pane_capture(muxly_client *client, const char *pane_id);
char *muxly_client_pane_split(muxly_client *client, const char *target, const char *direction, const char *command);
char *muxly_client_session_create(muxly_client *client, const char *session_name, const char *command);
/** @} */

/**
 * @name Structured status-returning variants
 *
 * These variants are recommended for new bindings.
 *
 * Response-oriented `_ex` functions return a muxly_status and write any
 * response string through `out_response`. When the returned status is
 * `MUXLY_STATUS_OK`, `*out_response` is a heap-allocated UTF-8 JSON-RPC payload
 * that must be released with muxly_string_free(). That payload may still be a
 * daemon-side JSON-RPC error object, so callers must inspect the envelope.
 *
 * When the returned status is not `MUXLY_STATUS_OK`, `*out_response` is set to
 * NULL and no response string was produced.
 *
 * @{
 */
muxly_status muxly_ping_ex(const char *socket_path, char **out_response);
muxly_status muxly_document_get_ex(const char *socket_path, char **out_response);
muxly_status muxly_graph_get_ex(const char *socket_path, char **out_response);

muxly_status muxly_client_ping_ex(muxly_client *client, char **out_response);
muxly_status muxly_client_document_get_ex(muxly_client *client, char **out_response);
muxly_status muxly_client_graph_get_ex(muxly_client *client, char **out_response);
muxly_status muxly_client_document_status_ex(muxly_client *client, char **out_response);

muxly_status muxly_client_node_get_ex(muxly_client *client, unsigned long long node_id, char **out_response);
muxly_status muxly_client_node_append_ex(
    muxly_client *client,
    unsigned long long parent_id,
    const char *kind,
    const char *title,
    char **out_response
);
/**
 * @brief Structured variant of muxly_client_node_update().
 *
 * Exactly one of `title` or `content` should normally be provided. Either may
 * be NULL as long as the other is non-null. If both are NULL, the call returns
 * `MUXLY_STATUS_INVALID_ARGUMENT` and no request is sent.
 *
 * @param client Handle created by muxly_client_create().
 * @param node_id muxly node id to update.
 * @param title Optional replacement title, or NULL.
 * @param content Optional replacement content, or NULL.
 * @param out_response Output pointer for the returned JSON-RPC payload.
 * @return `MUXLY_STATUS_OK` on transport success, otherwise a library-side
 * failure code. On failure, `*out_response` is set to NULL.
 */
muxly_status muxly_client_node_update_ex(
    muxly_client *client,
    unsigned long long node_id,
    const char *title,
    const char *content,
    char **out_response
);
muxly_status muxly_client_node_freeze_ex(
    muxly_client *client,
    unsigned long long node_id,
    const char *artifact_kind,
    char **out_response
);
muxly_status muxly_client_node_remove_ex(muxly_client *client, unsigned long long node_id, char **out_response);

muxly_status muxly_client_leaf_source_get_ex(muxly_client *client, unsigned long long node_id, char **out_response);
muxly_status muxly_client_view_clear_root_ex(muxly_client *client, char **out_response);
muxly_status muxly_client_view_set_root_ex(muxly_client *client, unsigned long long node_id, char **out_response);
muxly_status muxly_client_view_elide_ex(muxly_client *client, unsigned long long node_id, char **out_response);
muxly_status muxly_client_view_expand_ex(muxly_client *client, unsigned long long node_id, char **out_response);
muxly_status muxly_client_view_reset_ex(muxly_client *client, char **out_response);

muxly_status muxly_client_pane_capture_ex(muxly_client *client, const char *pane_id, char **out_response);
muxly_status muxly_client_pane_split_ex(
    muxly_client *client,
    const char *target,
    const char *direction,
    const char *command,
    char **out_response
);
muxly_status muxly_client_session_create_ex(
    muxly_client *client,
    const char *session_name,
    const char *command,
    char **out_response
);
/** @} */

/**
 * @brief Free any heap-allocated string returned by a muxly_* API above.
 *
 * Passing NULL is allowed. Do not free these strings with `free()`;
 * always use muxly_string_free().
 *
 * @param value String previously returned by a muxly_* API, or NULL.
 */
void muxly_string_free(char *value);

#ifdef __cplusplus
}
#endif

#endif

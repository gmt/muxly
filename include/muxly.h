#ifndef MUXLY_H
#define MUXLY_H

#ifdef __cplusplus
extern "C" {
#endif

/*
 * Opaque client handle. Create with muxly_client_create() and destroy with
 * muxly_client_destroy().
 */
typedef struct muxly_client muxly_client;

/*
 * Version string for the shared library.
 *
 * The returned pointer is static storage owned by libmuxly. Do not free it.
 */
const char *muxly_version(void);

/*
 * Stateless convenience helpers.
 *
 * `socket_path` must be a non-null NUL-terminated string.
 * On success these functions return a heap-allocated UTF-8 JSON-RPC response
 * payload that must be released with muxly_string_free().
 * On failure they return NULL.
 */
char *muxly_ping(const char *socket_path);
char *muxly_document_get(const char *socket_path);
char *muxly_graph_get(const char *socket_path);

/*
 * Handle-based client lifecycle.
 *
 * `socket_path` must be a non-null NUL-terminated string.
 * muxly_client_create() returns NULL on allocation failure.
 * Destroying a NULL client is allowed.
 */
muxly_client *muxly_client_create(const char *socket_path);
void muxly_client_destroy(muxly_client *client);

/*
 * Handle-based request helpers.
 *
 * Unless otherwise noted, `client` and any string arguments must be non-null.
 * On success each function returns a heap-allocated UTF-8 JSON-RPC response
 * payload that must be released with muxly_string_free().
 * On failure they return NULL.
 */
char *muxly_client_ping(muxly_client *client);
char *muxly_client_document_get(muxly_client *client);
char *muxly_client_graph_get(muxly_client *client);
char *muxly_client_document_status(muxly_client *client);

/* Node/view helpers use muxly node ids from earlier response payloads. */
char *muxly_client_node_get(muxly_client *client, unsigned long long node_id);
char *muxly_client_leaf_source_get(muxly_client *client, unsigned long long node_id);
char *muxly_client_view_set_root(muxly_client *client, unsigned long long node_id);
char *muxly_client_view_elide(muxly_client *client, unsigned long long node_id);

/* tmux helpers accept muxly pane ids or session names as NUL-terminated strings. */
char *muxly_client_pane_capture(muxly_client *client, const char *pane_id);
char *muxly_client_pane_split(muxly_client *client, const char *target, const char *direction, const char *command);
char *muxly_client_session_create(muxly_client *client, const char *session_name, const char *command);

/*
 * Free any heap-allocated string returned by a muxly_* API above.
 * Passing NULL is allowed.
 */
void muxly_string_free(char *value);

#ifdef __cplusplus
}
#endif

#endif

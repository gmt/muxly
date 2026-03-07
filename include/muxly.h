#ifndef MUXLY_H
#define MUXLY_H

#ifdef __cplusplus
extern "C" {
#endif

/*
 * Opaque ordinary-client handle. Create with muxly_client_create() and destroy
 * with muxly_client_destroy().
 */
typedef struct muxly_client muxly_client;

/* Static helper APIs: each returned string must be freed with muxly_string_free. */
const char *muxly_version(void);
char *muxly_ping(const char *socket_path);
char *muxly_document_get(const char *socket_path);
char *muxly_graph_get(const char *socket_path);

/* Handle-based client lifecycle. */
muxly_client *muxly_client_create(const char *socket_path);
void muxly_client_destroy(muxly_client *client);

/* Handle-based request helpers: every non-null string result must be freed. */
char *muxly_client_ping(muxly_client *client);
char *muxly_client_document_get(muxly_client *client);
char *muxly_client_graph_get(muxly_client *client);
char *muxly_client_document_status(muxly_client *client);
char *muxly_client_node_get(muxly_client *client, unsigned long long node_id);
char *muxly_client_leaf_source_get(muxly_client *client, unsigned long long node_id);
char *muxly_client_view_set_root(muxly_client *client, unsigned long long node_id);
char *muxly_client_view_elide(muxly_client *client, unsigned long long node_id);
char *muxly_client_pane_capture(muxly_client *client, const char *pane_id);
char *muxly_client_pane_split(muxly_client *client, const char *target, const char *direction, const char *command);
char *muxly_client_session_create(muxly_client *client, const char *session_name, const char *command);

/* Free any heap-allocated string returned by muxly APIs. */
void muxly_string_free(char *value);

#ifdef __cplusplus
}
#endif

#endif

#ifndef MUXLY_H
#define MUXLY_H

#ifdef __cplusplus
extern "C" {
#endif

typedef struct muxly_client muxly_client;

const char *muxly_version(void);
char *muxly_ping(const char *socket_path);
char *muxly_document_get(const char *socket_path);
char *muxly_graph_get(const char *socket_path);

muxly_client *muxly_client_create(const char *socket_path);
void muxly_client_destroy(muxly_client *client);
char *muxly_client_ping(muxly_client *client);
char *muxly_client_document_get(muxly_client *client);
char *muxly_client_graph_get(muxly_client *client);
char *muxly_client_document_status(muxly_client *client);
char *muxly_client_leaf_source_get(muxly_client *client, unsigned long long node_id);
char *muxly_client_view_set_root(muxly_client *client, unsigned long long node_id);
char *muxly_client_view_elide(muxly_client *client, unsigned long long node_id);
char *muxly_client_pane_capture(muxly_client *client, const char *pane_id);
char *muxly_client_pane_split(muxly_client *client, const char *target, const char *direction, const char *command);
char *muxly_client_session_create(muxly_client *client, const char *session_name, const char *command);

void muxly_string_free(char *value);

#ifdef __cplusplus
}
#endif

#endif

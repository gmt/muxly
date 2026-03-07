#include <stdio.h>
#include "muxly.h"

int main(void) {
    const char *version = muxly_version();
    muxly_client *client = muxly_client_create("/tmp/muxly.sock");
    char *response = muxly_client_ping(client);
    char *document = muxly_client_document_get(client);
    char *view_root = muxly_client_view_set_root(client, 2);
    char *graph = muxly_client_graph_get(client);
    char *node = muxly_client_node_get(client, 2);

    printf("muxly version: %s\n", version);
    if (client == NULL) {
        fprintf(stderr, "client create failed\n");
        return 1;
    }
    if (response != NULL) {
        printf("ping response: %s\n", response);
        muxly_string_free(response);
    } else {
        fprintf(stderr, "ping failed\n");
        return 1;
    }

    if (document != NULL) {
        printf("document response: %s\n", document);
        muxly_string_free(document);
    } else {
        fprintf(stderr, "document get failed\n");
        return 1;
    }

    if (view_root != NULL) {
        printf("view root response: %s\n", view_root);
        muxly_string_free(view_root);
    } else {
        fprintf(stderr, "view set root failed\n");
        return 1;
    }

    if (graph != NULL) {
        printf("graph response: %s\n", graph);
        muxly_string_free(graph);
    } else {
        fprintf(stderr, "graph get failed\n");
        return 1;
    }

    if (node != NULL) {
        printf("node response: %s\n", node);
        muxly_string_free(node);
    } else {
        fprintf(stderr, "node get failed\n");
        return 1;
    }

    muxly_client_destroy(client);
    return 0;
}

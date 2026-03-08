#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "muxly.h"

static const char *default_socket_path(void) {
    return "/tmp/muxly.sock";
}

static int print_owned(const char *label, char *value) {
    if (value == NULL) {
        fprintf(stderr, "%s failed\n", label);
        return 0;
    }
    printf("%s: %s\n", label, value);
    muxly_string_free(value);
    return 1;
}

static int parse_node_id(const char *response, unsigned long long *node_id_out) {
    const char *marker = "\"nodeId\":";
    const char *start = strstr(response, marker);
    if (start == NULL) {
        return 0;
    }
    start += strlen(marker);
    return sscanf(start, "%llu", node_id_out) == 1;
}

int main(void) {
    const char *socket_path = getenv("MUXLY_SOCKET");
    muxly_client *client;
    unsigned long long node_id = 0;
    char *append_response;

    if (socket_path == NULL || socket_path[0] == '\0') {
        socket_path = default_socket_path();
    }

    printf("muxly version: %s\n", muxly_version());
    printf("socket path: %s\n", socket_path);

    client = muxly_client_create(socket_path);
    if (client == NULL) {
        fprintf(stderr, "client create failed\n");
        return 1;
    }

    if (!print_owned("ping response", muxly_client_ping(client))) {
        muxly_client_destroy(client);
        return 1;
    }
    if (!print_owned("document status", muxly_client_document_status(client))) {
        muxly_client_destroy(client);
        return 1;
    }

    append_response = muxly_client_node_append(client, 1, "subdocument", "c abi scaffold");
    if (append_response == NULL) {
        fprintf(stderr, "node append failed\n");
        muxly_client_destroy(client);
        return 1;
    }
    if (!parse_node_id(append_response, &node_id)) {
        fprintf(stderr, "could not parse node id from append response: %s\n", append_response);
        muxly_string_free(append_response);
        muxly_client_destroy(client);
        return 1;
    }
    printf("node append: %s\n", append_response);
    muxly_string_free(append_response);

    if (!print_owned("node update", muxly_client_node_update(client, node_id, NULL, "hello synthetic api"))) {
        muxly_client_destroy(client);
        return 1;
    }
    if (!print_owned("node response", muxly_client_node_get(client, node_id))) {
        muxly_client_destroy(client);
        return 1;
    }
    if (!print_owned("view set root", muxly_client_view_set_root(client, node_id))) {
        muxly_client_destroy(client);
        return 1;
    }
    if (!print_owned("view elide", muxly_client_view_elide(client, node_id))) {
        muxly_client_destroy(client);
        return 1;
    }
    if (!print_owned("view expand", muxly_client_view_expand(client, node_id))) {
        muxly_client_destroy(client);
        return 1;
    }
    if (!print_owned("view clear root", muxly_client_view_clear_root(client))) {
        muxly_client_destroy(client);
        return 1;
    }
    if (!print_owned("view reset", muxly_client_view_reset(client))) {
        muxly_client_destroy(client);
        return 1;
    }

    if (!print_owned("document response", muxly_client_document_get(client))) {
        muxly_client_destroy(client);
        return 1;
    }
    if (!print_owned("graph response", muxly_client_graph_get(client))) {
        muxly_client_destroy(client);
        return 1;
    }
    if (!print_owned("node remove", muxly_client_node_remove(client, node_id))) {
        muxly_client_destroy(client);
        return 1;
    }

    muxly_client_destroy(client);
    return 0;
}

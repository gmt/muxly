#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>

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

int main(void) {
    const char *socket_path = getenv("MUXLY_SOCKET");
    char session_name[64];
    const char *command = "sh -lc 'printf hello-from-c-binding\\n; sleep 1'";
    muxly_client *client;

    if (socket_path == NULL || socket_path[0] == '\0') {
        socket_path = default_socket_path();
    }

    snprintf(session_name, sizeof(session_name), "muxly-c-example-%ld", (long)getpid());

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
    if (!print_owned("session create", muxly_client_session_create(client, session_name, command))) {
        muxly_client_destroy(client);
        return 1;
    }

    usleep(200 * 1000);

    if (!print_owned("document response", muxly_client_document_get(client))) {
        muxly_client_destroy(client);
        return 1;
    }
    if (!print_owned("graph response", muxly_client_graph_get(client))) {
        muxly_client_destroy(client);
        return 1;
    }

    muxly_client_destroy(client);
    return 0;
}

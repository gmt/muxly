#include <ctype.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#include "muxly.h"

static const char *TEXT_SESSION_NAME = "muxly-example-c-freeze-text";
static const char *SURFACE_SESSION_NAME = "muxly-example-c-freeze-surface";

static void cleanup_tmux_session(const char *session_name) {
    char command[256];
    snprintf(command, sizeof(command), "tmux kill-session -t %s >/dev/null 2>&1", session_name);
    (void)system(command);
}

static char *dup_range(const char *start, const char *end) {
    size_t len = (size_t)(end - start);
    char *value = (char *)malloc(len + 1);
    if (value == NULL) {
        return NULL;
    }
    memcpy(value, start, len);
    value[len] = '\0';
    return value;
}

static int extract_u64(const char *json, const char *key, unsigned long long *value_out) {
    char marker[64];
    const char *start;

    snprintf(marker, sizeof(marker), "\"%s\":", key);
    start = strstr(json, marker);
    if (start == NULL) {
        return 0;
    }
    start += strlen(marker);
    while (*start == ' ') {
        start++;
    }
    return sscanf(start, "%llu", value_out) == 1;
}

static char *extract_json_string(const char *json, const char *key) {
    char marker[64];
    const char *cursor;
    const char *start;
    size_t capacity = 64;
    size_t length = 0;
    char *value;

    snprintf(marker, sizeof(marker), "\"%s\":\"", key);
    start = strstr(json, marker);
    if (start == NULL) {
        return NULL;
    }
    cursor = start + strlen(marker);
    value = (char *)malloc(capacity);
    if (value == NULL) {
        return NULL;
    }

    while (*cursor != '\0') {
        char ch = *cursor++;
        if (ch == '"') {
            break;
        }
        if (ch == '\\') {
            char escaped = *cursor++;
            switch (escaped) {
                case 'n':
                    ch = '\n';
                    break;
                case 'r':
                    ch = '\r';
                    break;
                case 't':
                    ch = '\t';
                    break;
                case '\\':
                    ch = '\\';
                    break;
                case '"':
                    ch = '"';
                    break;
                default:
                    free(value);
                    return NULL;
            }
        }
        if (length + 1 >= capacity) {
            char *grown;
            capacity *= 2;
            grown = (char *)realloc(value, capacity);
            if (grown == NULL) {
                free(value);
                return NULL;
            }
            value = grown;
        }
        value[length++] = ch;
    }

    value[length] = '\0';
    return value;
}

static char *call_or_die(char *value, const char *label) {
    if (value == NULL) {
        fprintf(stderr, "%s failed\n", label);
        exit(1);
    }
    return value;
}

static void print_and_free(const char *label, char *value) {
    printf("\n== %s ==\n%s\n", label, value);
    muxly_string_free(value);
}

static char *take_json_copy_and_free(char *owned) {
    char *copy;
    if (owned == NULL) {
        return NULL;
    }
    copy = strdup(owned);
    muxly_string_free(owned);
    return copy;
}

static void wait_for_pane_content(muxly_client *client, const char *pane_id, const char *needle) {
    int attempts;
    for (attempts = 0; attempts < 40; attempts++) {
        char *capture = call_or_die(muxly_client_pane_capture(client, pane_id), "pane capture");
        if (strstr(capture, needle) != NULL) {
            muxly_string_free(capture);
            return;
        }
        muxly_string_free(capture);
        usleep(100000);
    }
    fprintf(stderr, "timed out waiting for pane %s to contain %s\n", pane_id, needle);
    exit(1);
}

static void print_sectioned_summary(const char *content) {
    const char *cursor = content;
    const char *line_start = cursor;
    char current_section[64] = "body";
    int line_count = 0;

    printf("\n== parsed surface sections ==\n");

    while (1) {
        if (*cursor == '\n' || *cursor == '\0') {
            char *line = dup_range(line_start, cursor);
            if (line == NULL) {
                fprintf(stderr, "out of memory while parsing surface content\n");
                exit(1);
            }

            if (line[0] == '[' && line[strlen(line) - 1] == ']') {
                size_t name_len = strlen(line) - 2;
                if (name_len >= sizeof(current_section)) {
                    name_len = sizeof(current_section) - 1;
                }
                memcpy(current_section, line + 1, name_len);
                current_section[name_len] = '\0';
                printf("%s:\n", current_section);
                line_count = 0;
            } else if (line[0] != '\0' && line_count < 6) {
                printf("  %s\n", line);
                line_count++;
            }

            free(line);

            if (*cursor == '\0') {
                break;
            }
            cursor++;
            line_start = cursor;
            continue;
        }
        cursor++;
    }
}

static char *build_surface_command(const char *surface_script_path) {
    size_t needed = strlen(surface_script_path) + 64;
    char *command = (char *)malloc(needed);
    if (command == NULL) {
        return NULL;
    }
    snprintf(command, needed, "sh -lc 'python3 -u \"%s\"'", surface_script_path);
    return command;
}

int main(int argc, char **argv) {
    const char *socket_path = getenv("MUXLY_SOCKET");
    const char *surface_script_path;
    muxly_client *client;
    char *surface_command;

    unsigned long long text_node_id = 0;
    unsigned long long surface_node_id = 0;

    char *text_session_response;
    char *text_node_response;
    char *text_freeze_response;
    char *text_frozen_node_response;

    char *surface_session_response;
    char *surface_node_response;
    char *surface_freeze_response;
    char *surface_frozen_node_response;

    char *text_pane_id;
    char *surface_pane_id;
    char *surface_content;

    if (argc < 2) {
        fprintf(stderr, "usage: %s /absolute/path/to/surface_chatter.py\n", argv[0]);
        return 1;
    }
    surface_script_path = argv[1];

    if (socket_path == NULL || socket_path[0] == '\0') {
        socket_path = "/tmp/muxly.sock";
    }

    cleanup_tmux_session(TEXT_SESSION_NAME);
    cleanup_tmux_session(SURFACE_SESSION_NAME);

    client = muxly_client_create(socket_path);
    if (client == NULL) {
        fprintf(stderr, "client create failed\n");
        return 1;
    }

    printf("muxly version: %s\n", muxly_version());
    printf("socket path: %s\n", socket_path);

    text_session_response = take_json_copy_and_free(call_or_die(
        muxly_client_session_create(client, TEXT_SESSION_NAME, "sh -lc 'printf \"%s\\n\" c-freeze-text; sleep 5'"),
        "session create (text)"));
    if (text_session_response == NULL || !extract_u64(text_session_response, "nodeId", &text_node_id)) {
        fprintf(stderr, "could not parse text node id\n");
        return 1;
    }
    text_node_response = take_json_copy_and_free(call_or_die(
        muxly_client_node_get(client, text_node_id),
        "node get (text)"));
    text_pane_id = extract_json_string(text_node_response, "paneId");
    if (text_pane_id == NULL) {
        fprintf(stderr, "could not parse text pane id\n");
        return 1;
    }
    wait_for_pane_content(client, text_pane_id, "c-freeze-text");
    text_freeze_response = call_or_die(muxly_client_node_freeze(client, text_node_id, "text"), "node freeze (text)");
    text_frozen_node_response = call_or_die(muxly_client_node_get(client, text_node_id), "node get frozen (text)");

    surface_command = build_surface_command(surface_script_path);
    if (surface_command == NULL) {
        fprintf(stderr, "could not build surface command\n");
        return 1;
    }
    surface_session_response = take_json_copy_and_free(call_or_die(
        muxly_client_session_create(client, SURFACE_SESSION_NAME, surface_command),
        "session create (surface)"));
    free(surface_command);
    if (surface_session_response == NULL || !extract_u64(surface_session_response, "nodeId", &surface_node_id)) {
        fprintf(stderr, "could not parse surface node id\n");
        return 1;
    }
    surface_node_response = take_json_copy_and_free(call_or_die(
        muxly_client_node_get(client, surface_node_id),
        "node get (surface)"));
    surface_pane_id = extract_json_string(surface_node_response, "paneId");
    if (surface_pane_id == NULL) {
        fprintf(stderr, "could not parse surface pane id\n");
        return 1;
    }
    wait_for_pane_content(client, surface_pane_id, "muxly surface demo");
    surface_freeze_response = call_or_die(muxly_client_node_freeze(client, surface_node_id, "surface"), "node freeze (surface)");
    surface_frozen_node_response = call_or_die(muxly_client_node_get(client, surface_node_id), "node get frozen (surface)");

    print_and_free("text freeze response", text_freeze_response);
    print_and_free("text frozen node", text_frozen_node_response);
    print_and_free("surface freeze response", surface_freeze_response);
    printf("\n== surface frozen node ==\n%s\n", surface_frozen_node_response);

    surface_content = extract_json_string(surface_frozen_node_response, "content");
    if (surface_content == NULL) {
        fprintf(stderr, "could not parse surface content\n");
        return 1;
    }
    print_sectioned_summary(surface_content);

    free(surface_content);
    free(text_session_response);
    free(text_node_response);
    free(text_pane_id);
    free(surface_session_response);
    free(surface_node_response);
    free(surface_pane_id);
    muxly_string_free(surface_frozen_node_response);
    muxly_client_destroy(client);
    cleanup_tmux_session(TEXT_SESSION_NAME);
    cleanup_tmux_session(SURFACE_SESSION_NAME);
    return 0;
}

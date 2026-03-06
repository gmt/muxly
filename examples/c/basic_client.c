#include <stdio.h>
#include "muxly.h"

int main(void) {
    const char *version = muxly_version();
    char *response = muxly_ping("/tmp/muxly.sock");
    char *document = muxly_document_get("/tmp/muxly.sock");

    printf("muxly version: %s\n", version);
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

    return 0;
}

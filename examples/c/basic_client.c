#include <stdio.h>
#include "muxly.h"

int main(void) {
    const char *version = muxly_version();
    char *response = muxly_ping("/tmp/muxly.sock");

    printf("muxly version: %s\n", version);
    if (response != NULL) {
        printf("ping response: %s\n", response);
        muxly_string_free(response);
    } else {
        fprintf(stderr, "ping failed\n");
        return 1;
    }

    return 0;
}

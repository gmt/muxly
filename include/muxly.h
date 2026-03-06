#ifndef MUXLY_H
#define MUXLY_H

#ifdef __cplusplus
extern "C" {
#endif

const char *muxly_version(void);
char *muxly_ping(const char *socket_path);
void muxly_string_free(char *value);

#ifdef __cplusplus
}
#endif

#endif

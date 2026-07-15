#include <stdlib.h>
#include "blake3.h"
void *fd_blake3_new(void) { blake3_hasher *value = malloc(sizeof(*value)); if (value) blake3_hasher_init(value); return value; }
void fd_blake3_update(void *value, const unsigned char *input, size_t length) { blake3_hasher_update(value, input, length); }
void fd_blake3_finalize(void *value, unsigned char output[32]) { blake3_hasher_finalize(value, output, 32); }
void fd_blake3_delete(void *value) { free(value); }

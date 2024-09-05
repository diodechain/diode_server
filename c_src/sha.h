#ifdef __SHA__
#include "sha256_asm.h"
#else
#include "sha256_std.h"
#endif

void sha(const uint8_t *message, uint64_t len, uint8_t *digest);

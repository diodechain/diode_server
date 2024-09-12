#include <stdint.h>
extern "C" {
#ifdef __SHA__
#include "sha256_asm.c"

void sha(const uint8_t *message, uint64_t len, uint8_t *digest)
{
    SHA256_CTX ctx;
    sha256_init(&ctx);
    sha256_update(&ctx, message, len);
    sha256_final(&ctx, digest);
}

#else
#include "sha256_std.c"

void sha(const uint8_t *message, uint64_t len, uint8_t *digest)
{
    sha256_ctx ctx;
    sha256_init(&ctx);
    sha256_update(&ctx, message, len);
    sha256_final(&ctx, digest);
}

#endif
}


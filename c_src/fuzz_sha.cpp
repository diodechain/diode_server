// libFuzzer harness for SHA-256 (sha.cpp / sha256_std.c). Build with:
//   clang++ -std=c++17 -I. -fsanitize=fuzzer,address -g -O1 -o fuzz_sha fuzz_sha.cpp sha.cpp -lstdc++
// Run: ./fuzz_sha -max_total_time=30

#include <cstddef>
#include <cstdint> // before sha.h (sha.h uses uint8_t without including)

extern "C" {
#include "sha.h"
}

extern "C" int LLVMFuzzerTestOneInput(const uint8_t *data, size_t size) {
    uint8_t digest[32];
    sha(data, static_cast<uint64_t>(size), digest);
    (void)digest;
    return 0;
}

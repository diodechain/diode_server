// Native RSS / copy spike harness (glibc Linux). Build: make -C c_src mem_harness
// Measures VmRSS before/after full Tree copy — models workload B (COW duplicate cost).

#include "merkletree.hpp"
#include <cctype>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <fstream>
#include <sstream>
#include <string>
#include <vector>

static long read_vm_rss_kb() {
    std::ifstream in("/proc/self/status");
    std::string line;
    while (std::getline(in, line)) {
        if (line.compare(0, 6, "VmRSS:") == 0) {
            std::istringstream iss(line);
            std::string label;
            long kb = 0;
            std::string unit;
            iss >> label >> kb >> unit;
            return kb;
        }
    }
    return -1;
}

static std::vector<uint256_t> test_keys(int size) {
    std::vector<uint256_t> out;
    out.reserve(size);
    bin_t buffer;
    for (int i = 0; i < size; i++) {
        buffer.resize(128);
        std::sprintf(reinterpret_cast<char *>(buffer.data()), "!%d!", i + 1);
        buffer.resize(std::strlen(reinterpret_cast<char *>(buffer.data())));
        uint256_t key = hash(buffer);
        out.push_back(key);
    }
    return out;
}

int main(int argc, char **argv) {
    int n = 1000;
    if (argc > 1) {
        n = std::atoi(argv[1]);
    }
    if (const char *env = std::getenv("MERKLE_N")) {
        n = std::atoi(env);
    }

    auto keys = test_keys(n);
    Tree base;
    for (uint256_t &key : keys) {
        bin_t bkey(key.data(), key.data() + 32);
        base.insert_item(bkey, key);
    }

    long rss0 = read_vm_rss_kb();
    Tree copy(base);
    long rss1 = read_vm_rss_kb();
    (void)copy.root_hash();

    std::printf("pairs=%d nodes_base=%zu nodes_copy=%zu vm_rss_kb=%ld -> %ld (delta=%ld)\n",
            n,
            base.node_count(),
            copy.node_count(),
            rss0,
            rss1,
            rss1 - rss0);
    return 0;
}

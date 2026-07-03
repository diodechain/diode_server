// Native Callgrind/Massif harness for State.uncompact hot path (no BEAM).
// Models optimized NIF path: lazy compact storage + root_hash/code_hash hashing + sorted state batch insert.
// Build: make -C c_src uncompact_harness.bin
// Profile: CALLGRIND_HOT=1 valgrind --tool=callgrind --instr-atstart=no ./c_src/uncompact_harness.bin 14609

#include "merkletree.hpp"
#include "rlp.hpp"
#include <algorithm>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <vector>

extern "C" void sha(const uint8_t *message, uint64_t len, uint8_t *digest);

struct uint160_t {
    uint8_t value[20];
};

struct AccountHashCtx {
    std::vector<uint8_t> nonce_rlp;
    std::vector<uint8_t> balance_rlp;
    std::vector<uint8_t> root_rlp;
    std::vector<uint8_t> code_rlp;
    std::vector<uint8_t> list_rlp;
    std::vector<uint8_t> list_payload;

    bool compute(uint64_t nonce, const uint256_t &balance, const uint256_t &storage_root,
            const uint256_t *code_hash_override, uint256_t &out)
    {
        uint256_t code_hash;
        if (code_hash_override != nullptr) {
            code_hash = *code_hash_override;
        } else {
            sha((const uint8_t *)"", 0, code_hash.data());
        }

        nonce_rlp.clear();
        balance_rlp.clear();
        root_rlp.clear();
        code_rlp.clear();
        list_rlp.clear();

        rlp_encode_uint64(nonce, nonce_rlp);
        rlp_encode_uint256(balance.value, balance_rlp);

        rlp_encode_bytes(storage_root.value, 32, root_rlp);
        rlp_encode_bytes(code_hash.value, 32, code_rlp);
        rlp_encode_list(nonce_rlp, balance_rlp, root_rlp, code_rlp, list_payload, list_rlp);
        sha(list_rlp.data(), list_rlp.size(), out.data());
        return true;
    }
};

static void put_u256(uint256_t &out, uint64_t v)
{
    memset(out.value, 0, sizeof(out.value));
    for (int i = 0; i < 8; i++) {
        out.value[31 - i] = (uint8_t)((v >> (8 * i)) & 0xFF);
    }
}

static void put_addr(uint160_t &out, int i)
{
    memset(out.value, 0, sizeof(out.value));
    out.value[18] = (uint8_t)((i >> 8) & 0xFF);
    out.value[19] = (uint8_t)(i & 0xFF);
}

static void put_slot_key(bin_t &slot, int i)
{
    slot.assign(32, 0);
    slot[30] = (uint8_t)((i >> 8) & 0xFF);
    slot[31] = (uint8_t)(i & 0xFF);
}

static std::vector<uint256_t> build_compact_roots(int n_accounts)
{
    std::vector<uint256_t> roots((size_t)n_accounts + 1);
    bin_t storage_key;
    for (int i = 1; i <= n_accounts; i++) {
        Tree storage_tree;
        put_slot_key(storage_key, i);
        uint256_t slot_val;
        put_u256(slot_val, (uint64_t)i + 1);
        storage_tree.insert_item(storage_key, slot_val);
        roots[(size_t)i] = storage_tree.root_hash();
    }
    return roots;
}

static std::vector<uint256_t> build_compact_code_hashes(int n_accounts)
{
    std::vector<uint256_t> hashes((size_t)n_accounts + 1);
    bin_t code_buf;
    for (int i = 1; i <= n_accounts; i++) {
        code_buf.assign(1, (uint8_t)i);
        sha(code_buf.data(), code_buf.size(), hashes[(size_t)i].data());
    }
    return hashes;
}

static void callgrind_hot_start()
{
    if (std::getenv("CALLGRIND_HOT")) {
        std::system("callgrind_control -i >/dev/null 2>&1");
    }
}

static void callgrind_hot_stop()
{
    if (std::getenv("CALLGRIND_HOT")) {
        std::system("callgrind_control -d >/dev/null 2>&1");
    }
}

int main(int argc, char **argv)
{
    int n_accounts = 14609;
    if (argc > 1) {
        n_accounts = std::atoi(argv[1]);
    }
    if (const char *env = std::getenv("UNCOMPACT_PROFILE_COUNT")) {
        n_accounts = std::atoi(env);
    }

    std::vector<uint256_t> compact_roots = build_compact_roots(n_accounts);
    std::vector<uint256_t> compact_code_hashes = build_compact_code_hashes(n_accounts);

    Tree state_tree;
    std::vector<std::pair<uint160_t, uint256_t>> pending;
    pending.reserve((size_t)n_accounts);

    AccountHashCtx hash_ctx;

    callgrind_hot_start();

    for (int i = 1; i <= n_accounts; i++) {
        uint256_t balance;
        put_u256(balance, (uint64_t)i * 1000ULL);

        uint256_t account_hash;
        hash_ctx.compute((uint64_t)i, balance, compact_roots[(size_t)i],
                &compact_code_hashes[(size_t)i], account_hash);

        uint160_t addr;
        put_addr(addr, i);
        pending.push_back({addr, account_hash});
    }

    std::sort(pending.begin(), pending.end(), [](const auto &a, const auto &b) {
        return memcmp(a.first.value, b.first.value, 20) < 0;
    });

    bin_t addr_key;
    for (auto &item : pending) {
        addr_key.assign(item.first.value, item.first.value + 20);
        state_tree.insert_item(addr_key, item.second);
    }

    callgrind_hot_stop();

    uint256_t root = state_tree.root_hash();
    std::printf("uncompact_harness ok: %d accounts root[0]=%02x\n",
            n_accounts, root.value[0]);
    return 0;
}

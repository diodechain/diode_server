#ifdef __linux__
#ifndef _GNU_SOURCE
#define _GNU_SOURCE
#endif
#endif

extern "C" {
#include <erl_nif.h>
#include "sha.h"
}

#include "merkletree.hpp"
#include "rlp.hpp"
#include <algorithm>
#include <atomic>
#include <cstring>
#include <cstdio>
#include <memory>
#include <unordered_map>
#include <unordered_set>
#include <vector>
#ifdef __GLIBC__
#include <malloc.h>
#endif

static constexpr size_t kNifTimesliceInterval = 512;

static void nif_loop_progress(ErlNifEnv *env, size_t i)
{
    if (env && i > 0 && (i % kNifTimesliceInterval) == 0) {
        (void)enif_consume_timeslice(env, 1);
    }
}

static void print(const char *msg);
static ErlNifResourceType *merkletree_type = NULL;
static ErlNifResourceType *accountmap_type = NULL;
static ErlNifMutex *stats_mutex = NULL;
static uint256_t empty_code_hash;
static ERL_NIF_TERM make_atom(ErlNifEnv *env, const char *atom_name);
static ERL_NIF_TERM make_binary(ErlNifEnv *env, uint8_t *data, size_t size);
static volatile int shared_states = 0;
static volatile int resources = 0;
static int locked_states_cnt = 0;
static int orphan_shared_states = 0;
static int lazy_clone_count = 0;
static int eager_clone_count = 0;

class LockedStates;
static LockedStates* locked_states;


#ifdef DEBUG
#define STAT(cmd) { enif_mutex_lock(stats_mutex); cmd; enif_mutex_unlock(stats_mutex); }
static void print(const char *msg) {
    static int ops = 0;
    
    if (ops++ % 10000 == 0) {
        fprintf(stderr, "%s [shared_states=%d] [locked_states=%d] [resources=%d]\n", msg, shared_states, locked_states_cnt, resources); fflush(stderr);
    }
}
#else
#define STAT(cmd) {}
static void print(const char */*msg*/) {}
#endif

class SharedState {
public:
    ErlNifMutex *mtx;
    int has_clone;
    std::atomic<int> read_pins;
    Tree tree;
    SharedState() : tree() {
        mtx = enif_mutex_create((char*)"merkletree_mutex");
        has_clone = 0;
        read_pins.store(0, std::memory_order_relaxed);
        enif_mutex_lock(stats_mutex);
        shared_states++;
        enif_mutex_unlock(stats_mutex);
        print("CREATE");
    }

    SharedState(SharedState &other) : tree(other.tree) {
        mtx = enif_mutex_create((char*)"merkletree_mutex");
        has_clone = 0;
        read_pins.store(0, std::memory_order_relaxed);
        enif_mutex_lock(stats_mutex);
        shared_states++;
        enif_mutex_unlock(stats_mutex);
        print("CLONE");
    }

    ~SharedState() {
        enif_mutex_lock(stats_mutex);
        shared_states--;
        enif_mutex_unlock(stats_mutex);
        print("DESTROY");
        enif_mutex_destroy(mtx);
    }
};

struct  merkletree {
    bool locked;
    SharedState *shared_state;
};

static merkletree *empty_storage_tree = nullptr;

static merkletree *alloc_merkletree_resource();

class Lock {
    ErlNifMutex *mtx;
public:
    Lock(merkletree *mt) : mtx(mt->shared_state->mtx) {
        enif_mutex_lock(mtx);
    }

    void unlock() {
        if (mtx) {
            enif_mutex_unlock(mtx);
            mtx = 0;
        }
    }

    ~Lock() {
        unlock();
    }
};

/* Lock one or two SharedState mutexes in a fixed address order (matches difference_raw). */
class SharedStateLock {
    SharedState *first;
    SharedState *second;
    bool dual;

public:
    explicit SharedStateLock(SharedState *state)
        : first(state), second(nullptr), dual(false) {
        enif_mutex_lock(first->mtx);
    }

    SharedStateLock(SharedState *s1, SharedState *s2) {
        if (s1 == s2) {
            first = s1;
            second = nullptr;
            dual = false;
            enif_mutex_lock(first->mtx);
        } else if (s1 < s2) {
            first = s1;
            second = s2;
            dual = true;
            enif_mutex_lock(s1->mtx);
            enif_mutex_lock(s2->mtx);
        } else {
            first = s2;
            second = s1;
            dual = true;
            enif_mutex_lock(s2->mtx);
            enif_mutex_lock(s1->mtx);
        }
    }

    void unlock() {
        if (!first) {
            return;
        }
        if (dual) {
            enif_mutex_unlock(second->mtx);
        }
        enif_mutex_unlock(first->mtx);
        first = nullptr;
        second = nullptr;
        dual = false;
    }

    ~SharedStateLock() {
        unlock();
    }
};

static void switch_local_to_canonical(merkletree *mt, SharedState *local, SharedState *canonical);

static bool shared_state_reclaimable(SharedState *state) {
    return state != nullptr &&
        state->has_clone == 0 &&
        state->read_pins.load(std::memory_order_acquire) == 0;
}

static void classify_shared_state_reclaim(SharedState *state, SharedState **dead, SharedState **orphan) {
    if (shared_state_reclaimable(state)) {
        *dead = state;
    } else {
        *orphan = state;
    }
}

static void pin_shared_state_read(SharedState *state) {
    if (state != nullptr) {
        state->read_pins.fetch_add(1, std::memory_order_acq_rel);
    }
}

static void unpin_shared_state_read(SharedState *state) {
    if (state != nullptr) {
        state->read_pins.fetch_sub(1, std::memory_order_acq_rel);
    }
}

static void keep_storage_in_map(merkletree *mt);
static void release_storage_from_map(merkletree *mt);
static merkletree *clone_merkletree_locked(merkletree *mt);

struct uint160_t {
    uint8_t value[20];

    uint160_t() : value{0} {}

    uint160_t(const uint8_t *data) {
        memcpy(value, data, sizeof(value));
    }

    bool operator==(const uint160_t &other) const {
        return memcmp(value, other.value, sizeof(value)) == 0;
    }

    bool operator<(const uint160_t &other) const {
        return memcmp(value, other.value, sizeof(value)) < 0;
    }
};

namespace std {
template<>
struct hash<uint160_t> {
    std::size_t operator()(const uint160_t &k) const {
        std::size_t h = 0;
        for (unsigned i = 0; i < sizeof(k.value); i++) {
            h = h * 31 + k.value[i];
        }
        return h;
    }
};
}

struct StorageSlot {
    bin_t key;
    uint256_t value;
};

struct CompactStorage {
    std::vector<StorageSlot> slots;
};

static std::unique_ptr<CompactStorage> clone_compact_storage(const CompactStorage *src)
{
    if (src == nullptr) {
        return nullptr;
    }
    auto dup = std::make_unique<CompactStorage>();
    dup->slots = src->slots;
    return dup;
}

struct AccountEntry {
    uint64_t nonce;
    uint256_t balance;
    merkletree *storage;
    std::unique_ptr<CompactStorage> compact_storage;
    bin_t code;

    AccountEntry()
        : nonce(0), balance(), storage(nullptr), compact_storage(nullptr), code() {}

    AccountEntry(const AccountEntry &other)
        : nonce(other.nonce), balance(other.balance), storage(other.storage),
          compact_storage(clone_compact_storage(other.compact_storage.get())), code(other.code)
    {
    }

    AccountEntry(AccountEntry &&other) noexcept
        : nonce(other.nonce), balance(other.balance), storage(other.storage),
          compact_storage(std::move(other.compact_storage)), code(std::move(other.code))
    {
        other.storage = nullptr;
    }

    AccountEntry &operator=(const AccountEntry &other)
    {
        if (this != &other) {
            nonce = other.nonce;
            balance = other.balance;
            storage = other.storage;
            code = other.code;
            compact_storage = clone_compact_storage(other.compact_storage.get());
        }
        return *this;
    }

    AccountEntry &operator=(AccountEntry &&other) noexcept
    {
        if (this != &other) {
            nonce = other.nonce;
            balance = other.balance;
            storage = other.storage;
            compact_storage = std::move(other.compact_storage);
            code = std::move(other.code);
            other.storage = nullptr;
        }
        return *this;
    }
};

static void release_entry_storage(AccountEntry &entry);
static merkletree *materialize_storage(AccountEntry &entry);
static ERL_NIF_TERM account_entry_to_term(ErlNifEnv *env, AccountEntry &entry);

class SharedAccountMap {
public:
    ErlNifMutex *mtx;
    bool frozen;
    merkletree *state_trie;
    std::unordered_map<uint160_t, AccountEntry> accounts;

    SharedAccountMap() : frozen(false), state_trie(nullptr) {
        mtx = enif_mutex_create((char*)"accountmap_mutex");
        // alloc_merkletree_resource starts at refcount 1 — that ref is map-owned.
        state_trie = alloc_merkletree_resource();
    }

    ~SharedAccountMap() {
        for (auto &entry : accounts) {
            release_entry_storage(entry.second);
        }
        if (state_trie != nullptr) {
            release_storage_from_map(state_trie);
            state_trie = nullptr;
        }
        enif_mutex_destroy(mtx);
    }
};

struct accountmap {
    SharedAccountMap *shared;
};

class AccountMapLock {
    ErlNifMutex *mtx;
public:
    AccountMapLock(accountmap *am) : mtx(am->shared->mtx) {
        enif_mutex_lock(mtx);
    }

    void unlock() {
        if (mtx) {
            enif_mutex_unlock(mtx);
            mtx = 0;
        }
    }

    ~AccountMapLock() {
        unlock();
    }
};

class DualAccountMapLock {
    ErlNifMutex *first_mtx;
    ErlNifMutex *second_mtx;
    bool dual;

public:
    DualAccountMapLock(SharedAccountMap *s1, SharedAccountMap *s2)
        : first_mtx(nullptr), second_mtx(nullptr), dual(false) {
        if (s1 == s2) {
            first_mtx = s1->mtx;
            enif_mutex_lock(first_mtx);
        } else if (s1 < s2) {
            dual = true;
            first_mtx = s1->mtx;
            second_mtx = s2->mtx;
            enif_mutex_lock(s1->mtx);
            enif_mutex_lock(s2->mtx);
        } else {
            dual = true;
            first_mtx = s2->mtx;
            second_mtx = s1->mtx;
            enif_mutex_lock(s2->mtx);
            enif_mutex_lock(s1->mtx);
        }
    }

    ~DualAccountMapLock() {
        if (!first_mtx) {
            return;
        }
        if (dual) {
            enif_mutex_unlock(second_mtx);
        }
        enif_mutex_unlock(first_mtx);
    }
};

static void keep_storage_in_map(merkletree *mt)
{
    if (mt != nullptr) {
        enif_keep_resource(mt);
    }
}

static void release_storage_from_map(merkletree *mt)
{
    if (mt != nullptr) {
        enif_release_resource(mt);
    }
}

static void release_entry_storage(AccountEntry &entry)
{
    if (entry.storage != nullptr && entry.storage != empty_storage_tree) {
        release_storage_from_map(entry.storage);
    }
    entry.storage = nullptr;
    entry.compact_storage.reset();
}

// Allocates a new merkletree resource sharing mt's SharedState (has_clone += 1) with
// locked = false so a fork can COW-write. Returns a resource with refcount 1 (the
// caller's ownership): pair with enif_make_resource + enif_release_resource for an
// Elixir term, or enif_keep_resource + enif_release_resource for C-side ownership.
static merkletree *clone_merkletree_locked(merkletree *mt)
{
    Lock lock(mt);
    merkletree *clone = (merkletree*)enif_alloc_resource(merkletree_type, sizeof(merkletree));
    STAT(resources++);
    clone->shared_state = mt->shared_state;
    clone->locked = false;
    clone->shared_state->has_clone += 1;
    return clone;
}

// New SharedAccountMap with cloned state_trie + distinct storage wrappers that share
// SharedState until first write. Caller owns the returned pointer.
static SharedAccountMap *fork_shared_accountmap(ErlNifEnv *env, SharedAccountMap *src)
{
    SharedAccountMap *new_shared = new SharedAccountMap();
    new_shared->accounts = src->accounts;
    release_storage_from_map(new_shared->state_trie);
    {
        merkletree *st = clone_merkletree_locked(src->state_trie);
        new_shared->state_trie = st;
        keep_storage_in_map(st);
        enif_release_resource(st);
    }

    std::unordered_map<merkletree*, merkletree*> storage_clones;
    size_t i = 0;
    for (auto &entry : new_shared->accounts) {
        i++;
        if (entry.second.compact_storage) {
            nif_loop_progress(env, i);
            continue;
        }
        merkletree *orig = entry.second.storage;
        if (orig == nullptr) {
            continue;
        }
        auto it = storage_clones.find(orig);
        if (it == storage_clones.end()) {
            merkletree *storage_clone = clone_merkletree_locked(orig);
            it = storage_clones.insert({orig, storage_clone}).first;
        }
        enif_keep_resource(it->second);
        entry.second.storage = it->second;
        nif_loop_progress(env, i);
    }
    for (auto &kv : storage_clones) {
        enif_release_resource(kv.second);
    }
    return new_shared;
}

static bool get_address(ErlNifEnv *env, ERL_NIF_TERM term, uint160_t &out)
{
    ErlNifBinary bin;
    if (!enif_inspect_binary(env, term, &bin) || bin.size != 20) {
        return false;
    }
    out = uint160_t(bin.data);
    return true;
}

static bool decode_ext_uint256(const uint8_t *data, size_t size, uint256_t &out)
{
    static constexpr uint8_t kExtTermVersion = 131;
    static constexpr uint8_t kExtSmallInteger = 'a';
    static constexpr uint8_t kExtInteger = 'b';
    static constexpr uint8_t kExtSmallBig = 'n';
    static constexpr uint8_t kExtLargeBig = 'o';

    memset(out.value, 0, sizeof(out.value));
    if (size < 2) {
        return false;
    }
    const uint8_t *p = data;
    if (*p++ != kExtTermVersion) {
        return false;
    }
    if (p >= data + size) {
        return false;
    }
    uint8_t tag = *p++;
    switch (tag) {
    case kExtSmallInteger: {
        if (p >= data + size) {
            return false;
        }
        out.value[31] = *p;
        return true;
    }
    case kExtInteger: {
        if (p + 4 > data + size) {
            return false;
        }
        int32_t val = (int32_t)((p[0] << 24) | (p[1] << 16) | (p[2] << 8) | p[3]);
        if (val < 0) {
            return false;
        }
        for (int i = 0; i < 4; i++) {
            out.value[31 - i] = (uint8_t)((val >> (8 * i)) & 0xFF);
        }
        return true;
    }
    case kExtSmallBig: {
        if (p + 2 > data + size) {
            return false;
        }
        uint8_t n = *p++;
        uint8_t sign = *p++;
        if (sign != 0 || n > 32) {
            return false;
        }
        if (p + n > data + size) {
            return false;
        }
        for (uint8_t i = 0; i < n; i++) {
            out.value[31 - i] = p[i];
        }
        return true;
    }
    case kExtLargeBig: {
        if (p + 5 > data + size) {
            return false;
        }
        uint32_t n = ((uint32_t)p[0] << 24) | ((uint32_t)p[1] << 16) |
            ((uint32_t)p[2] << 8) | (uint32_t)p[3];
        p += 4;
        uint8_t sign = *p++;
        if (sign != 0 || n > 32) {
            return false;
        }
        if (p + n > data + size) {
            return false;
        }
        for (uint32_t i = 0; i < n; i++) {
            out.value[31 - i] = p[i];
        }
        return true;
    }
    default:
        return false;
    }
}

static bool get_balance_uint256(ErlNifEnv *env, ERL_NIF_TERM term, uint256_t &out)
{
    memset(out.value, 0, sizeof(out.value));
    ErlNifUInt64 u64;
    if (enif_get_uint64(env, term, &u64)) {
        for (int i = 0; i < 8; i++) {
            out.value[31 - i] = (uint8_t)((u64 >> (8 * i)) & 0xFF);
        }
        return true;
    }
    ErlNifSInt64 s64;
    if (enif_get_int64(env, term, &s64) && s64 >= 0) {
        uint64_t val = (uint64_t)s64;
        for (int i = 0; i < 8; i++) {
            out.value[31 - i] = (uint8_t)((val >> (8 * i)) & 0xFF);
        }
        return true;
    }
    ErlNifBinary bin;
    if (enif_inspect_binary(env, term, &bin) && bin.size > 0 && bin.size <= 32) {
        memcpy(out.value + (32 - bin.size), bin.data, bin.size);
        return true;
    }
    ErlNifBinary ext;
    if (!enif_term_to_binary(env, term, &ext)) {
        return false;
    }
    return decode_ext_uint256(ext.data, ext.size, out);
}

static ERL_NIF_TERM balance_to_term(ErlNifEnv *env, const uint256_t &balance)
{
    int start = 0;
    while (start < 32 && balance.value[start] == 0) {
        start++;
    }
    if (start == 32) {
        return enif_make_uint(env, 0);
    }
    size_t len = (size_t)(32 - start);
    if (len <= 8) {
        uint64_t val = 0;
        for (size_t i = 0; i < len; i++) {
            val = (val << 8) | balance.value[start + i];
        }
        return enif_make_uint64(env, val);
    }
    unsigned char *blob;
    ERL_NIF_TERM term;
    blob = enif_make_new_binary(env, len, &term);
    if (!blob) {
        return make_atom(env, "error");
    }
    memcpy(blob, balance.value + start, len);
    return term;
}

static bool get_code(ErlNifEnv *env, ERL_NIF_TERM term, bin_t &out)
{
    out.clear();
    if (enif_is_atom(env, term)) {
        char atom[16];
        if (enif_get_atom(env, term, atom, sizeof(atom), ERL_NIF_LATIN1) &&
            strcmp(atom, "nil") == 0) {
            return true;
        }
        return false;
    }
    ErlNifBinary bin;
    if (!enif_inspect_binary(env, term, &bin)) {
        return false;
    }
    out.insert(out.end(), bin.data, bin.data + bin.size);
    return true;
}

static ERL_NIF_TERM code_to_term(ErlNifEnv *env, const bin_t &code)
{
    if (code.empty()) {
        unsigned char *blob;
        ERL_NIF_TERM term;
        blob = enif_make_new_binary(env, 0, &term);
        if (!blob) {
            return make_atom(env, "error");
        }
        return term;
    }
    return make_binary(env, (uint8_t*)code.data(), code.size());
}

static bool make_writeable_accountmap(accountmap *am)
{
    return !am->shared->frozen;
}

static void destroy_shared_accountmap(accountmap *am, AccountMapLock &lock)
{
    lock.unlock();
    delete am->shared;
    am->shared = NULL;
}

class LockedStates {
public:
    std::unordered_map<uint256_t, SharedState*> states;
    std::vector<SharedState*> pending_orphans;
    ErlNifMutex *mtx;

    LockedStates() {
        mtx = enif_mutex_create((char*)"locked_states_mutex");
    }

    ~LockedStates() {
        enif_mutex_destroy(mtx);
    }

    void enqueue_orphan(SharedState *state) {
        if (state == nullptr) {
            return;
        }
        enif_mutex_lock(mtx);
        if (std::find(pending_orphans.begin(), pending_orphans.end(), state) ==
                pending_orphans.end()) {
            pending_orphans.push_back(state);
            orphan_shared_states = (int)pending_orphans.size();
        }
        enif_mutex_unlock(mtx);
    }

    void remove_pending_orphan(SharedState *state) {
        if (state == nullptr) {
            return;
        }
        enif_mutex_lock(mtx);
        auto it = std::find(pending_orphans.begin(), pending_orphans.end(), state);
        if (it != pending_orphans.end()) {
            pending_orphans.erase(it);
            orphan_shared_states = (int)pending_orphans.size();
        }
        enif_mutex_unlock(mtx);
    }

    void try_reclaim_orphans() {
        std::vector<SharedState*> snapshot;
        enif_mutex_lock(mtx);
        snapshot = pending_orphans;
        enif_mutex_unlock(mtx);

        for (SharedState *candidate : snapshot) {
            enif_mutex_lock(mtx);
            auto it = std::find(pending_orphans.begin(), pending_orphans.end(), candidate);
            if (it == pending_orphans.end()) {
                enif_mutex_unlock(mtx);
                continue;
            }
            pending_orphans.erase(it);
            orphan_shared_states = (int)pending_orphans.size();
            enif_mutex_unlock(mtx);

            if (enif_mutex_trylock(candidate->mtx) != 0) {
                enqueue_orphan(candidate);
                continue;
            }
            if (!shared_state_reclaimable(candidate)) {
                enif_mutex_unlock(candidate->mtx);
                enqueue_orphan(candidate);
                continue;
            }
            enif_mutex_unlock(candidate->mtx);
            delete candidate;
        }
    }

    void switch_to_canonical_locked(merkletree *mt, SharedState *local, SharedState *canonical) {
        enif_mutex_lock(local->mtx);
        local->has_clone += 1;
        enif_mutex_unlock(local->mtx);
        enif_mutex_lock(canonical->mtx);
        canonical->has_clone += 1;
        enif_mutex_unlock(canonical->mtx);
        unpin_shared_state_read(canonical);
        switch_local_to_canonical(mt, local, canonical);
        enif_mutex_lock(mtx);
        if (mt->shared_state != canonical) {
            enif_mutex_lock(canonical->mtx);
            if (canonical->has_clone > 0) {
                canonical->has_clone -= 1;
            }
            enif_mutex_unlock(canonical->mtx);
        }
        enif_mutex_unlock(mtx);
        try_reclaim_orphans();
    }

    void enter_lock(merkletree *mt) {
        locked_states_cnt = (int)states.size();
        print("ENTER_LOCK");

        SharedState *local = nullptr;
        uint256_t root_hash;

        {
            Lock lock(mt);
            mt->locked = true;
            local = mt->shared_state;
            root_hash = local->tree.root_hash();
        }

        enif_mutex_lock(mtx);
        SharedState *canonical = nullptr;
        auto it = states.find(root_hash);
        if (it != states.end()) {
            if (it->second == local) {
                enif_mutex_unlock(mtx);
                enif_mutex_lock(local->mtx);
                local->has_clone += 1;
                enif_mutex_unlock(local->mtx);
                return;
            }
            canonical = it->second;
            pin_shared_state_read(canonical);
        } else {
            states[root_hash] = local;
            enif_mutex_unlock(mtx);
            enif_mutex_lock(local->mtx);
            local->has_clone += 1;
            enif_mutex_unlock(local->mtx);
            return;
        }
        enif_mutex_unlock(mtx);

        if (canonical) {
            switch_to_canonical_locked(mt, local, canonical);
        }
    }

    /* Lock a trie whose root_hash is already registered; repoint to canonical SharedState. */
    void apply_canonical_lock(merkletree *mt, const uint256_t &root_hash) {
        enif_mutex_lock(mtx);
        auto it = states.find(root_hash);
        if (it == states.end()) {
            enif_mutex_unlock(mtx);
            enter_lock(mt);
            return;
        }

        SharedState *canonical = it->second;
        pin_shared_state_read(canonical);
        enif_mutex_unlock(mtx);

        SharedState *local = nullptr;
        {
            Lock lock(mt);
            mt->locked = true;
            local = mt->shared_state;
            if (local == canonical) {
                enif_mutex_lock(canonical->mtx);
                canonical->has_clone += 1;
                enif_mutex_unlock(canonical->mtx);
                unpin_shared_state_read(canonical);
                return;
            }
        }

        switch_to_canonical_locked(mt, local, canonical);
    }

    void leave_lock(merkletree *mt) {
        locked_states_cnt = (int)states.size();
        print("LEAVE_LOCK");

        SharedState *state = mt->shared_state;
        if (state == nullptr) {
            return;
        }

        bool was_locked = mt->locked;
        mt->locked = false;

        uint256_t root_hash;
        SharedState *dead = nullptr;
        SharedState *orphan = nullptr;
        bool erase_map_entry = false;

        if (was_locked) {
            enif_mutex_lock(mtx);
            enif_mutex_lock(state->mtx);
            root_hash = state->tree.root_hash();

            if (state->has_clone > 0) {
                state->has_clone -= 1;
            }
            mt->shared_state = nullptr;
            erase_map_entry = (state->has_clone == 0);

            if (state->has_clone == 0) {
                classify_shared_state_reclaim(state, &dead, &orphan);
            }

            if (erase_map_entry) {
                auto it = states.find(root_hash);
                if (it != states.end() && it->second == state) {
                    states.erase(it);
                }
            }

            enif_mutex_unlock(state->mtx);
            enif_mutex_unlock(mtx);
        } else {
            enif_mutex_lock(state->mtx);
            if (state->has_clone == 0) {
                classify_shared_state_reclaim(state, &dead, &orphan);
                mt->shared_state = nullptr;
            } else {
                state->has_clone -= 1;
                mt->shared_state = nullptr;
            }
            enif_mutex_unlock(state->mtx);
        }

        if (dead != nullptr) {
            remove_pending_orphan(dead);
            delete dead;
        }
        if (orphan != nullptr) {
            enqueue_orphan(orphan);
        }

        try_reclaim_orphans();
    }

    int locked_count() const {
        return (int)states.size();
    }

    int orphan_count() const {
        return orphan_shared_states;
    }
};

static void switch_local_to_canonical(merkletree *mt, SharedState *local, SharedState *canonical)
{
    if (local == canonical) {
        return;
    }

    SharedState *lo = local < canonical ? local : canonical;
    SharedState *hi = local < canonical ? canonical : local;
    enif_mutex_lock(lo->mtx);
    enif_mutex_lock(hi->mtx);

    if (mt->shared_state != local) {
        enif_mutex_unlock(hi->mtx);
        enif_mutex_unlock(lo->mtx);
        return;
    }

    SharedState *abandoned = nullptr;
    if (local->has_clone == 0) {
        mt->shared_state = nullptr;
        enif_mutex_unlock(local->mtx);
        if (shared_state_reclaimable(local)) {
            abandoned = local;
        } else {
            locked_states->enqueue_orphan(local);
        }
    } else {
        local->has_clone -= 1;
        mt->shared_state = nullptr;
        enif_mutex_unlock(local->mtx);
        if (local->has_clone == 0) {
            if (shared_state_reclaimable(local)) {
                abandoned = local;
            } else {
                locked_states->enqueue_orphan(local);
            }
        }
    }
    mt->shared_state = canonical;

    if (local == lo) {
        enif_mutex_unlock(hi->mtx);
    } else {
        enif_mutex_unlock(lo->mtx);
    }

    if (abandoned != nullptr) {
        locked_states->enqueue_orphan(abandoned);
    }
}

static ERL_NIF_TERM
make_atom(ErlNifEnv *env, const char *atom_name)
{
    ERL_NIF_TERM atom;
    if(enif_make_existing_atom(env, atom_name, &atom, ERL_NIF_LATIN1)) return atom;
    return enif_make_atom(env, atom_name);
}

static ERL_NIF_TERM
make_binary(ErlNifEnv *env, uint8_t *data, size_t size)
{
    ERL_NIF_TERM term;
    unsigned char *blob = enif_make_new_binary(env, size, &term);
    if (!blob) {
        return make_atom(env, "error");
    }
    memcpy(blob, data, size);
    return term;
}


static ERL_NIF_TERM
merkletree_new(ErlNifEnv *env, int argc, const ERL_NIF_TERM[] /*argv[]*/)
{
    if (argc != 0) return enif_make_badarg(env);
    merkletree *mt = alloc_merkletree_resource();
    ERL_NIF_TERM res = enif_make_resource(env, mt);
    enif_release_resource(mt);
    return res;
}

static ERL_NIF_TERM
merkletree_clone(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[])
{
    merkletree *mt;
    if (argc != 1) return enif_make_badarg(env);
    if (!enif_get_resource(env, argv[0], merkletree_type, (void **) &mt)) return enif_make_badarg(env);

    merkletree *clone = clone_merkletree_locked(mt);
    ERL_NIF_TERM res = enif_make_resource(env, clone);
    enif_release_resource(clone);
    return res;
}


/* In-place COW: when SharedState is shared (has_clone > 0), detach this resource onto a
 * privately-owned SharedState copy. Caller must hold mt->shared_state->mtx. */
static bool make_writeable_locked(merkletree *mt)
{
    if (mt->locked) {
        return false;
    }

    SharedState *state = mt->shared_state;
    if (state->has_clone > 0) {
        state->has_clone -= 1;
        mt->shared_state = new SharedState(*state);
        enif_mutex_unlock(state->mtx);
        enif_mutex_lock(mt->shared_state->mtx);
        print("CREATING (UNCLONING)");
    }
    return true;
}

static bool decode_storage_slot(const ErlNifBinary &key_binary,
        const ErlNifBinary &value_binary, StorageSlot &out)
{
    if (value_binary.size != 32) {
        return false;
    }
    out.key.assign(key_binary.data, key_binary.data + key_binary.size);
    out.value = (char*)value_binary.data;
    return true;
}

static bool insert_binary_pair(Tree &tree, const ErlNifBinary &key_binary,
        const ErlNifBinary &value_binary, bin_t &key_scratch)
{
    StorageSlot slot;
    if (!decode_storage_slot(key_binary, value_binary, slot)) {
        return false;
    }
    key_scratch = slot.key;
    tree.insert_item(key_scratch, slot.value);
    return true;
}

static bool insert_binary_terms(ErlNifEnv *env, Tree &tree, ERL_NIF_TERM key_term,
        ERL_NIF_TERM value_term, bin_t &key_scratch)
{
    ErlNifBinary key_binary, value_binary;
    if (!enif_inspect_binary(env, key_term, &key_binary)) {
        return false;
    }
    if (!enif_inspect_binary(env, value_term, &value_binary)) {
        return false;
    }
    return insert_binary_pair(tree, key_binary, value_binary, key_scratch);
}

static ERL_NIF_TERM
merkletree_insert_item(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[])
{
    merkletree *mt;
    ErlNifBinary key_binary, value_binary;

    if (argc != 3) return enif_make_badarg(env);
    if (!enif_get_resource(env, argv[0], merkletree_type, (void **) &mt)) return enif_make_badarg(env);

    if (!enif_inspect_binary(env, argv[1], &key_binary)) return enif_make_badarg(env);
    if (!enif_inspect_binary(env, argv[2], &value_binary)) return enif_make_badarg(env);

    enif_mutex_lock(mt->shared_state->mtx);
    if (!make_writeable_locked(mt)) {
        enif_mutex_unlock(mt->shared_state->mtx);
        return enif_make_badarg(env);
    }
    bin_t key_scratch;
    if (!insert_binary_pair(mt->shared_state->tree, key_binary, value_binary, key_scratch)) {
        enif_mutex_unlock(mt->shared_state->mtx);
        return enif_make_badarg(env);
    }
    enif_mutex_unlock(mt->shared_state->mtx);
    return argv[0];
}

namespace {

struct RangeEntry {
    bin_t key;
    uint256_t value;
};

static bool uint256_increment(uint8_t key[32])
{
    for (int i = 31; i >= 0; i--) {
        if (key[i] != 0xFF) {
            key[i]++;
            return true;
        }
        key[i] = 0;
    }
    return false;
}

static size_t get_range_entries(Tree &tree, const bin_t &base_key, size_t count, RangeEntry *out)
{
    if (count == 0 || base_key.size() != 32) {
        return 0;
    }

    uint8_t key_bytes[32];
    memcpy(key_bytes, base_key.data(), 32);

    size_t written = 0;
    for (size_t i = 0; i < count; i++) {
        bin_t key(key_bytes, key_bytes + 32);
        pair_t lookup(std::move(key));
        pair_t *pair = tree.get_item(lookup);

        out[written].key = lookup.key;
        out[written].value = pair == nullptr ? uint256_t() : pair->value;
        written++;

        if (i + 1 < count && !uint256_increment(key_bytes)) {
            break;
        }
    }

    return written;
}

} // namespace

static ERL_NIF_TERM
merkletree_get_range(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[])
{
    merkletree *mt;
    ErlNifBinary key_binary;
    unsigned count;

    if (argc != 3) return enif_make_badarg(env);
    if (!enif_get_resource(env, argv[0], merkletree_type, (void **) &mt)) return enif_make_badarg(env);
    if (!enif_inspect_binary(env, argv[1], &key_binary)) return enif_make_badarg(env);
    if (key_binary.size != 32) return enif_make_badarg(env);
    if (!enif_get_uint(env, argv[2], &count)) return enif_make_badarg(env);
    if (count < 1 || count > 256) return enif_make_badarg(env);

    Lock lock(mt);

    bin_t key;
    key.insert(key.end(), key_binary.data, key_binary.data + key_binary.size);

    std::vector<RangeEntry> entries(count);
    size_t n = get_range_entries(mt->shared_state->tree, key, count, entries.data());

    ERL_NIF_TERM list = enif_make_list(env, 0);
    for (size_t i = n; i > 0; i--) {
        RangeEntry &entry = entries[i - 1];
        ERL_NIF_TERM key_term = make_binary(env, entry.key.data(), entry.key.size());
        ERL_NIF_TERM value_term = make_binary(env, entry.value.data(), 32);
        ERL_NIF_TERM pair = enif_make_tuple2(env, key_term, value_term);
        list = enif_make_list_cell(env, pair, list);
    }

    return list;
}

static ERL_NIF_TERM
merkletree_get_item(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[])
{
    merkletree *mt;
    ErlNifBinary key_binary;

    if (argc != 2) return enif_make_badarg(env);
    if (!enif_get_resource(env, argv[0], merkletree_type, (void **) &mt)) return enif_make_badarg(env);
    Lock lock(mt);
    if (!enif_inspect_binary(env, argv[1], &key_binary)) return enif_make_badarg(env);
    if (key_binary.size != 32) return enif_make_badarg(env);

    bin_t key;
    key.insert(key.end(), key_binary.data, key_binary.data + key_binary.size);
    pair_t *pair = mt->shared_state->tree.get_item(std::move(key));

    if (pair == nullptr) {
        return make_atom(env, "nil");
    }

    ERL_NIF_TERM key_term = argv[1];
    ERL_NIF_TERM value_term = make_binary(env, pair->value.data(), 32);
    ERL_NIF_TERM hash_term = make_binary(env, pair->key_hash.data(), 32);
    return enif_make_tuple3(env, key_term, value_term, hash_term);
}

static ERL_NIF_TERM
make_proof(ErlNifEnv *env, proof_t& proof)
{
    switch (proof.type) {
        case 0:
            return enif_make_tuple2(env, make_proof(env, *proof.left), make_proof(env, *proof.right));
        case 1:
            return make_binary(env, proof.hash.data(), 32);
        case 2:
        {
            ERL_NIF_TERM ret;
            if (!enif_binary_to_term(env, proof.term.data(), proof.term.size(), &ret, 0)) {
                return make_atom(env, "error");
            }
            return ret;
        }
        default:
            return make_atom(env, "error");
    }
}

static ERL_NIF_TERM
merkletree_get_proofs(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[])
{
    merkletree *mt;
    ErlNifBinary key_binary;

    if (argc != 2) return enif_make_badarg(env);
    if (!enif_get_resource(env, argv[0], merkletree_type, (void **) &mt)) return enif_make_badarg(env);
    Lock lock(mt);
    if (!enif_inspect_binary(env, argv[1], &key_binary)) return enif_make_badarg(env);

    bin_t key;
    key.insert(key.end(), key_binary.data, key_binary.data + key_binary.size);
    proof_t proof = mt->shared_state->tree.get_proofs(key);
    return make_proof(env, proof);
}

static ERL_NIF_TERM
merkletree_to_list(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[])
{
    merkletree *mt;

    if (argc != 1) return enif_make_badarg(env);
    if (!enif_get_resource(env, argv[0], merkletree_type, (void **) &mt)) return enif_make_badarg(env);
    Lock lock(mt);
    ERL_NIF_TERM list = enif_make_list(env, 0);
    size_t i = 0;
    mt->shared_state->tree.each([&](pair_t &pair) {
        i++;
        ERL_NIF_TERM key_term = make_binary(env, pair.key.data(), pair.key.size());
        ERL_NIF_TERM value_term = make_binary(env, pair.value.data(), 32);
        ERL_NIF_TERM tuple = enif_make_tuple2(env, key_term, value_term);
        list = enif_make_list_cell(env, tuple, list);
        nif_loop_progress(env, i);
    });
    return list;
}

static ERL_NIF_TERM
merkletree_lock(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[])
{
    merkletree *mt;
    if (argc != 1) return enif_make_badarg(env);
    if (!enif_get_resource(env, argv[0], merkletree_type, (void **) &mt)) return enif_make_badarg(env);
    locked_states->enter_lock(mt);
    return argv[0];
}

static ERL_NIF_TERM
merkletree_difference(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[])
{
    merkletree *mt1;
    merkletree *mt2;

    if (argc != 2) return enif_make_badarg(env);
    if (!enif_get_resource(env, argv[0], merkletree_type, (void **) &mt1)) return enif_make_badarg(env);
    if (!enif_get_resource(env, argv[1], merkletree_type, (void **) &mt2)) return enif_make_badarg(env);

    if (mt1 == mt2) {
        return enif_make_list(env, 0);
    }

    SharedState *s1;
    SharedState *s2;
    enif_mutex_lock(locked_states->mtx);
    s1 = mt1->shared_state;
    s2 = mt2->shared_state;
    if (s1 == s2) {
        enif_mutex_unlock(locked_states->mtx);
        return enif_make_list(env, 0);
    }
    pin_shared_state_read(s1);
    pin_shared_state_read(s2);
    enif_mutex_unlock(locked_states->mtx);

    if (s1 == nullptr || s2 == nullptr) {
        unpin_shared_state_read(s2);
        unpin_shared_state_read(s1);
        return enif_make_list(env, 0);
    }

    SharedStateLock state_lock(s1, s2);

    Tree output;
    s1->tree.difference(s2->tree, output);
    s2->tree.difference(s1->tree, output);

    ERL_NIF_TERM list = enif_make_list(env, 0);
    size_t i = 0;
    output.each([&](pair_t &pair) {
        i++;
        ERL_NIF_TERM key_term = make_binary(env, pair.key.data(), pair.key.size());

        auto pair1 = s1->tree.get_item(pair);
        auto pair2 = s2->tree.get_item(pair);

        ERL_NIF_TERM value1_term = pair1 == nullptr ? make_atom(env, "nil") : make_binary(env, pair1->value.data(), 32);
        ERL_NIF_TERM value2_term = pair2 == nullptr ? make_atom(env, "nil") : make_binary(env, pair2->value.data(), 32);
        ERL_NIF_TERM tuple = enif_make_tuple2(env, value1_term, value2_term);
        tuple = enif_make_tuple2(env, key_term, tuple);
        list = enif_make_list_cell(env, tuple, list);
        nif_loop_progress(env, i);
    });

    unpin_shared_state_read(s2);
    unpin_shared_state_read(s1);
    state_lock.unlock();
    locked_states->try_reclaim_orphans();
    return list;
}

static ERL_NIF_TERM
merkletree_import_map(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[])
{
    merkletree *mt;

    if (argc != 2) return enif_make_badarg(env);
    if (!enif_get_resource(env, argv[0], merkletree_type, (void **) &mt)) return enif_make_badarg(env);
    if (!enif_is_map(env, argv[1])) return enif_make_badarg(env);

    enif_mutex_lock(mt->shared_state->mtx);
    if (!make_writeable_locked(mt)) {
        enif_mutex_unlock(mt->shared_state->mtx);
        return enif_make_badarg(env);
    }

    ERL_NIF_TERM key, value;
    ErlNifMapIterator iter;
    enif_map_iterator_create(env, argv[1], &iter, ERL_NIF_MAP_ITERATOR_FIRST);

    size_t i = 0;
    bin_t key_scratch;
    while (enif_map_iterator_get_pair(env, &iter, &key, &value)) {
        i++;
        if (!insert_binary_terms(env, mt->shared_state->tree, key, value, key_scratch)) {
            enif_mutex_unlock(mt->shared_state->mtx);
            goto import_badarg;
        }
        enif_map_iterator_next(env, &iter);
        nif_loop_progress(env, i);
    }
    enif_mutex_unlock(mt->shared_state->mtx);
    enif_map_iterator_destroy(env, &iter);
    return argv[0];

import_badarg:
    enif_map_iterator_destroy(env, &iter);
    return enif_make_badarg(env);
}

static ERL_NIF_TERM
merkletree_root_hash(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[])
{
    merkletree *mt;
    if (argc != 1) return enif_make_badarg(env);
    if (!enif_get_resource(env, argv[0], merkletree_type, (void **) &mt)) return enif_make_badarg(env);
    Lock lock(mt);
    auto root_hash = mt->shared_state->tree.root_hash();
    return make_binary(env, root_hash.data(), 32);
}

static ERL_NIF_TERM
merkletree_hash(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[])
{
    ErlNifBinary key_binary;

    if (argc != 1) return enif_make_badarg(env);
    if (!enif_inspect_binary(env, argv[0], &key_binary)) return enif_make_badarg(env);

    uint256_t hash = {};
    sha((const uint8_t*)key_binary.data, key_binary.size, hash.data());
    return make_binary(env, hash.data(), 32);
}

static ERL_NIF_TERM
merkletree_root_hashes(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[])
{
    merkletree *mt;
    if (argc != 1) return enif_make_badarg(env);
    if (!enif_get_resource(env, argv[0], merkletree_type, (void **) &mt)) return enif_make_badarg(env);
    Lock lock(mt);
    auto root_hashes = mt->shared_state->tree.root_hashes();
    return make_binary(env, (uint8_t*)root_hashes, 32*16);
}

static ERL_NIF_TERM
merkletree_size(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[])
{
    merkletree *mt;
    if (argc != 1) return enif_make_badarg(env);
    if (!enif_get_resource(env, argv[0], merkletree_type, (void **) &mt)) return enif_make_badarg(env);
    Lock lock(mt);
    auto size = mt->shared_state->tree.size();
    return enif_make_uint(env, size);
}

static ERL_NIF_TERM
merkletree_bucket_count(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[])
{
    merkletree *mt;
    if (argc != 1) return enif_make_badarg(env);
    if (!enif_get_resource(env, argv[0], merkletree_type, (void **) &mt)) return enif_make_badarg(env);
    Lock lock(mt);
    auto size = mt->shared_state->tree.leaf_count();
    return enif_make_uint(env, size);
}

static ERL_NIF_TERM
merkletree_struct_sizes(ErlNifEnv *env, int argc, const ERL_NIF_TERM /*argv*/[])
{
    if (argc != 0) {
        return enif_make_badarg(env);
    }
    return enif_make_tuple5(env,
            enif_make_uint64(env, sizeof(Item)),
            enif_make_uint64(env, sizeof(pair_t)),
            enif_make_uint64(env, sizeof(pair_list_t)),
            enif_make_uint64(env, sizeof(Tree)),
            enif_make_uint64(env, MERKLE_STRIPE_SIZE));
}

static ERL_NIF_TERM
merkletree_memory_stats(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[])
{
    merkletree *mt;
    if (argc != 1) {
        return enif_make_badarg(env);
    }
    if (!enif_get_resource(env, argv[0], merkletree_type, (void **) &mt)) {
        return enif_make_badarg(env);
    }
    Lock lock(mt);
    Tree &t = mt->shared_state->tree;
    size_t nodes = t.node_count();
    size_t pairs = t.size();
    uint64_t approx =
            (uint64_t)nodes * (uint64_t)sizeof(Item) + (uint64_t)pairs * (uint64_t)sizeof(pair_t);
    return enif_make_tuple3(env,
            enif_make_uint64(env, nodes),
            enif_make_uint64(env, pairs),
            enif_make_uint64(env, approx));
}

static ERL_NIF_TERM
merkletree_nif_stats(ErlNifEnv *env, int argc, const ERL_NIF_TERM /*argv*/[])
{
    if (argc != 0) {
        return enif_make_badarg(env);
    }

    int locked = 0;
    int orphans = 0;
    int shared = 0;
    int res = 0;

    int lazy = 0;
    int eager = 0;

    enif_mutex_lock(stats_mutex);
    shared = shared_states;
    res = resources;
    lazy = lazy_clone_count;
    eager = eager_clone_count;
    enif_mutex_unlock(stats_mutex);

    if (locked_states != nullptr) {
        enif_mutex_lock(locked_states->mtx);
        locked = locked_states->locked_count();
        orphans = locked_states->orphan_count();
        enif_mutex_unlock(locked_states->mtx);
    }

    ERL_NIF_TERM locked_term = enif_make_int(env, locked);
    ERL_NIF_TERM orphans_term = enif_make_int(env, orphans);
    ERL_NIF_TERM shared_term = enif_make_int(env, shared);
    ERL_NIF_TERM resources_term = enif_make_int(env, res);
    ERL_NIF_TERM lazy_term = enif_make_int(env, lazy);
    ERL_NIF_TERM eager_term = enif_make_int(env, eager);
    return enif_make_tuple6(env, locked_term, orphans_term, shared_term, resources_term,
            lazy_term, eager_term);
}

static ERL_NIF_TERM
merkletree_malloc_info(ErlNifEnv *env, int argc, const ERL_NIF_TERM /*argv*/[])
{
    if (argc != 0) {
        return enif_make_badarg(env);
    }
#ifdef __GLIBC__
    char *buf = NULL;
    size_t sz = 0;
    FILE *fp = open_memstream(&buf, &sz);
    if (!fp) {
        return make_atom(env, "error");
    }
    malloc_info(0, fp);
    fclose(fp);
    ERL_NIF_TERM term = make_binary(env, (uint8_t *)buf, sz);
    free(buf);
    return term;
#else
    return make_atom(env, "unsupported");
#endif
}

static ERL_NIF_TERM
merkletree_count_zeros(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[])
{
    ErlNifBinary bin;
    if (argc != 1) return enif_make_badarg(env);
    if (!enif_inspect_binary(env, argv[0], &bin)) return enif_make_badarg(env);

    uint64_t count = 0;
    for (size_t i = 0; i < bin.size; i++) {
        if (bin.data[i] == 0) count++;
        nif_loop_progress(env, i + 1);
    }
    return enif_make_uint64(env, count);
}

static ERL_NIF_TERM
account_map_new(ErlNifEnv *env, int argc, const ERL_NIF_TERM[] /*argv[]*/)
{
    if (argc != 0) return enif_make_badarg(env);
    accountmap *am = (accountmap*)enif_alloc_resource(accountmap_type, sizeof(accountmap));
    am->shared = new SharedAccountMap();
    ERL_NIF_TERM res = enif_make_resource(env, am);
    enif_release_resource(am);
    return res;
}

static ERL_NIF_TERM
account_map_clone(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[])
{
    accountmap *am;
    if (argc != 1) return enif_make_badarg(env);
    if (!enif_get_resource(env, argv[0], accountmap_type, (void **)&am)) return enif_make_badarg(env);

    AccountMapLock lock(am);

    // Eagerly fork so the clone is writable while a frozen parent stays immutable.
    // Distinct merkletree wrappers share SharedState until first write.
    SharedAccountMap *new_shared = fork_shared_accountmap(env, am->shared);

    accountmap *clone = (accountmap*)enif_alloc_resource(accountmap_type, sizeof(accountmap));
    clone->shared = new_shared;
    enif_mutex_lock(stats_mutex);
    eager_clone_count++;
    enif_mutex_unlock(stats_mutex);
    ERL_NIF_TERM res = enif_make_resource(env, clone);
    enif_release_resource(clone);
    return res;
}

static ERL_NIF_TERM
account_map_clone_lazy(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[])
{
    accountmap *am;
    if (argc != 1) return enif_make_badarg(env);
    if (!enif_get_resource(env, argv[0], accountmap_type, (void **)&am)) return enif_make_badarg(env);

    AccountMapLock lock(am);

    if (am->shared->frozen) {
        return enif_make_badarg(env);
    }

    // Speculative forks reject frozen parents and locked storage tries.
    for (auto &entry : am->shared->accounts) {
        if (!entry.second.compact_storage && entry.second.storage != nullptr &&
            entry.second.storage->locked) {
            return enif_make_badarg(env);
        }
    }

    SharedAccountMap *new_shared = fork_shared_accountmap(env, am->shared);

    accountmap *clone = (accountmap*)enif_alloc_resource(accountmap_type, sizeof(accountmap));
    clone->shared = new_shared;
    enif_mutex_lock(stats_mutex);
    lazy_clone_count++;
    enif_mutex_unlock(stats_mutex);
    ERL_NIF_TERM res = enif_make_resource(env, clone);
    enif_release_resource(clone);
    return res;
}

static ERL_NIF_TERM
account_map_lock(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[])
{
    accountmap *am;

    if (argc != 1) return enif_make_badarg(env);
    if (!enif_get_resource(env, argv[0], accountmap_type, (void **)&am)) return enif_make_badarg(env);

    AccountMapLock lock(am);
    am->shared->frozen = true;

    locked_states->try_reclaim_orphans();
    return argv[0];
}

static ERL_NIF_TERM account_entry_to_term(ErlNifEnv *env, AccountEntry &entry)
{
    merkletree *storage = materialize_storage(entry);
    ERL_NIF_TERM nonce = enif_make_uint64(env, entry.nonce);
    ERL_NIF_TERM balance = balance_to_term(env, entry.balance);
    ERL_NIF_TERM storage_term = enif_make_resource(env, storage);
    ERL_NIF_TERM code = code_to_term(env, entry.code);
    return enif_make_tuple4(env, nonce, balance, storage_term, code);
}

struct AccountHashCtx {
    std::vector<uint8_t> nonce_rlp;
    std::vector<uint8_t> balance_rlp;
    std::vector<uint8_t> root_rlp;
    std::vector<uint8_t> code_rlp;
    std::vector<uint8_t> list_rlp;
    std::vector<uint8_t> list_payload;

    bool compute(const AccountEntry &entry, const uint256_t *storage_root_override,
            const uint256_t *code_hash_override, uint256_t &out)
    {
        uint256_t storage_root;
        if (storage_root_override != nullptr) {
            storage_root = *storage_root_override;
        } else {
            if (entry.storage == nullptr) {
                return false;
            }
            Lock lock(entry.storage);
            storage_root = entry.storage->shared_state->tree.root_hash();
        }

        uint256_t code_hash;
        if (code_hash_override != nullptr) {
            code_hash = *code_hash_override;
        } else if (entry.code.empty()) {
            code_hash = empty_code_hash;
        } else {
            sha(entry.code.data(), entry.code.size(), code_hash.data());
        }

        nonce_rlp.clear();
        balance_rlp.clear();
        root_rlp.clear();
        code_rlp.clear();
        list_rlp.clear();

        rlp_encode_uint64(entry.nonce, nonce_rlp);
        rlp_encode_uint256(entry.balance.value, balance_rlp);
        rlp_encode_bytes(storage_root.data(), 32, root_rlp);
        rlp_encode_bytes(code_hash.data(), 32, code_rlp);

        rlp_encode_list(nonce_rlp, balance_rlp, root_rlp, code_rlp, list_payload, list_rlp);
        sha(list_rlp.data(), list_rlp.size(), out.data());
        return true;
    }
};

static void insert_state_trie_hash(SharedAccountMap *shared, const uint160_t &addr, const uint256_t &hash)
{
    bin_t key(addr.value, addr.value + 20);
    merkletree *mt = shared->state_trie;
    enif_mutex_lock(mt->shared_state->mtx);
    if (!make_writeable_locked(mt)) {
        enif_mutex_unlock(mt->shared_state->mtx);
        return;
    }
    uint256_t hash_value = hash;
    mt->shared_state->tree.insert_item(key, hash_value);
    enif_mutex_unlock(mt->shared_state->mtx);
}

static void update_state_trie_for_entry(SharedAccountMap *shared, const uint160_t &addr,
        AccountEntry &entry, AccountHashCtx &ctx)
{
    if (entry.storage == nullptr && !entry.compact_storage) {
        materialize_storage(entry);
    }
    uint256_t account_hash;
    if (!ctx.compute(entry, nullptr, nullptr, account_hash)) {
        return;
    }
    insert_state_trie_hash(shared, addr, account_hash);
}

static void remove_state_trie_entry(SharedAccountMap *shared, const uint160_t &addr)
{
    uint256_t zero;
    insert_state_trie_hash(shared, addr, zero);
}

static ERL_NIF_TERM
account_map_state_trie(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[])
{
    accountmap *am;
    if (argc != 1) return enif_make_badarg(env);
    if (!enif_get_resource(env, argv[0], accountmap_type, (void **)&am)) return enif_make_badarg(env);

    AccountMapLock lock(am);
    ERL_NIF_TERM term = enif_make_resource(env, am->shared->state_trie);
    enif_keep_resource(am->shared->state_trie);
    return term;
}

static ERL_NIF_TERM
account_map_get(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[])
{
    accountmap *am;
    uint160_t addr;

    if (argc != 2) return enif_make_badarg(env);
    if (!enif_get_resource(env, argv[0], accountmap_type, (void **)&am)) return enif_make_badarg(env);
    if (!get_address(env, argv[1], addr)) return enif_make_badarg(env);

    AccountMapLock lock(am);
    auto it = am->shared->accounts.find(addr);
    if (it == am->shared->accounts.end()) {
        return make_atom(env, "undefined");
    }

    AccountEntry &entry = it->second;
    return account_entry_to_term(env, entry);
}

static ERL_NIF_TERM
account_map_put(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[])
{
    accountmap *am;
    uint160_t addr;
    ErlNifUInt64 nonce;
    uint256_t balance;
    merkletree *storage;
    bin_t code;

    if (argc != 6) return enif_make_badarg(env);
    if (!enif_get_resource(env, argv[0], accountmap_type, (void **)&am)) return enif_make_badarg(env);
    if (!get_address(env, argv[1], addr)) return enif_make_badarg(env);
    if (!enif_get_uint64(env, argv[2], &nonce)) return enif_make_badarg(env);
    if (!get_balance_uint256(env, argv[3], balance)) return enif_make_badarg(env);
    if (!enif_get_resource(env, argv[4], merkletree_type, (void **)&storage)) return enif_make_badarg(env);
    if (!get_code(env, argv[5], code)) return enif_make_badarg(env);

    AccountMapLock lock(am);
    if (!make_writeable_accountmap(am)) return enif_make_badarg(env);

    auto it = am->shared->accounts.find(addr);
    if (it != am->shared->accounts.end()) {
        release_entry_storage(it->second);
        keep_storage_in_map(storage);
        it->second.nonce = (uint64_t)nonce;
        it->second.balance = balance;
        it->second.storage = storage;
        it->second.code = code;
    } else {
        keep_storage_in_map(storage);
        AccountEntry entry;
        entry.nonce = (uint64_t)nonce;
        entry.balance = balance;
        entry.storage = storage;
        entry.code = code;
        am->shared->accounts[addr] = std::move(entry);
    }

    AccountHashCtx hash_ctx;
    update_state_trie_for_entry(am->shared, addr, am->shared->accounts[addr], hash_ctx);
    return argv[0];
}

static ERL_NIF_TERM
account_map_delete(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[])
{
    accountmap *am;
    uint160_t addr;

    if (argc != 2) return enif_make_badarg(env);
    if (!enif_get_resource(env, argv[0], accountmap_type, (void **)&am)) return enif_make_badarg(env);
    if (!get_address(env, argv[1], addr)) return enif_make_badarg(env);

    AccountMapLock lock(am);
    if (!make_writeable_accountmap(am)) return enif_make_badarg(env);

    auto it = am->shared->accounts.find(addr);
    if (it != am->shared->accounts.end()) {
        release_entry_storage(it->second);
        am->shared->accounts.erase(it);
        remove_state_trie_entry(am->shared, addr);
    }
    return argv[0];
}

static ERL_NIF_TERM
account_map_root_hash(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[])
{
    accountmap *am;
    if (argc != 1) return enif_make_badarg(env);
    if (!enif_get_resource(env, argv[0], accountmap_type, (void **)&am)) return enif_make_badarg(env);

    AccountMapLock lock(am);
    Lock tree_lock(am->shared->state_trie);
    uint256_t root = am->shared->state_trie->shared_state->tree.root_hash();
    return make_binary(env, root.data(), 32);
}

static ERL_NIF_TERM
account_map_size(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[])
{
    accountmap *am;
    if (argc != 1) return enif_make_badarg(env);
    if (!enif_get_resource(env, argv[0], accountmap_type, (void **)&am)) return enif_make_badarg(env);

    AccountMapLock lock(am);
    return enif_make_uint(env, (unsigned)am->shared->accounts.size());
}

static ERL_NIF_TERM
account_map_to_list(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[])
{
    accountmap *am;
    if (argc != 1) return enif_make_badarg(env);
    if (!enif_get_resource(env, argv[0], accountmap_type, (void **)&am)) return enif_make_badarg(env);

    AccountMapLock lock(am);
    ERL_NIF_TERM list = enif_make_list(env, 0);
    size_t i = 0;
    for (auto &entry : am->shared->accounts) {
        i++;
        ERL_NIF_TERM addr = make_binary(env, (uint8_t*)entry.first.value, 20);
        ERL_NIF_TERM account = account_entry_to_term(env, entry.second);
        ERL_NIF_TERM pair = enif_make_tuple2(env, addr, account);
        list = enif_make_list_cell(env, pair, list);
        nif_loop_progress(env, i);
    }
    return list;
}

static merkletree *alloc_merkletree_resource()
{
    merkletree *mt = (merkletree*)enif_alloc_resource(merkletree_type, sizeof(merkletree));
    STAT(resources++);
    mt->shared_state = new SharedState();
    mt->locked = false;
    return mt;
}

static merkletree *materialize_storage(AccountEntry &entry)
{
    if (entry.storage != nullptr) {
        return entry.storage;
    }
    if (!entry.compact_storage || entry.compact_storage->slots.empty()) {
        // Fresh empty tree — never share empty_storage_tree as a writable map entry
        // (in-place COW would mutate the singleton for every account).
        // alloc refcount 1 is owned by the map entry (same as ensure_account_entry).
        merkletree *mt = alloc_merkletree_resource();
        entry.storage = mt;
        entry.compact_storage.reset();
        return entry.storage;
    }
    merkletree *mt = alloc_merkletree_resource();
    {
        Lock lock(mt);
        for (auto &slot : entry.compact_storage->slots) {
            mt->shared_state->tree.insert_item(slot.key, slot.value);
        }
    }
    entry.storage = mt;
    entry.compact_storage.reset();
    return entry.storage;
}

static bool storage_root_hash_for_entry(ErlNifEnv *env, const AccountEntry &entry,
        uint256_t &out, size_t progress_base)
{
    if (entry.storage != nullptr) {
        Lock lock(entry.storage);
        out = entry.storage->shared_state->tree.root_hash();
        return true;
    }
    if (!entry.compact_storage || entry.compact_storage->slots.empty()) {
        Lock lock(empty_storage_tree);
        out = empty_storage_tree->shared_state->tree.root_hash();
        return true;
    }
    Tree temp;
    size_t i = 0;
    for (auto &slot : entry.compact_storage->slots) {
        i++;
        temp.insert_item(slot.key, slot.value);
        nif_loop_progress(env, progress_base + i);
    }
    out = temp.root_hash();
    return true;
}

struct DiffAccountSide {
    bool present;
    uint64_t nonce;
    uint256_t balance;
    bin_t code;
    merkletree *storage;
    std::unique_ptr<CompactStorage> compact_storage;

    DiffAccountSide()
        : present(false), nonce(0), balance(), storage(nullptr), compact_storage(nullptr) {}
};

static void release_snapshot_side(DiffAccountSide &side)
{
    if (side.present && side.storage != nullptr) {
        enif_release_resource(side.storage);
        side.storage = nullptr;
    }
    side.compact_storage.reset();
    side.present = false;
}

static void snapshot_side(const AccountEntry &src, DiffAccountSide &out)
{
    out.present = true;
    out.nonce = src.nonce;
    out.balance = src.balance;
    out.code = src.code;
    out.storage = src.storage;
    out.compact_storage = clone_compact_storage(src.compact_storage.get());
    if (src.storage != nullptr) {
        enif_keep_resource(src.storage);
    }
}

static AccountEntry side_to_entry(DiffAccountSide &side)
{
    AccountEntry entry;
    entry.nonce = side.nonce;
    entry.balance = side.balance;
    entry.code = side.code;
    entry.storage = side.storage;
    entry.compact_storage = std::move(side.compact_storage);
    return entry;
}

static ERL_NIF_TERM diff_side_to_term(ErlNifEnv *env, DiffAccountSide &side)
{
    if (!side.present) {
        return make_atom(env, "nil");
    }
    AccountEntry entry = side_to_entry(side);
    ERL_NIF_TERM term = account_entry_to_term(env, entry);
    release_entry_storage(entry);
    side.storage = nullptr;
    return term;
}

static bool entries_equal(ErlNifEnv *env, const AccountEntry &a, const AccountEntry &b, size_t progress_base)
{
    if (a.nonce != b.nonce || a.balance != b.balance || a.code != b.code) {
        return false;
    }
    if (a.storage != nullptr && a.storage == b.storage) {
        return true;
    }
    uint256_t root_a, root_b;
    storage_root_hash_for_entry(env, a, root_a, progress_base);
    storage_root_hash_for_entry(env, b, root_b, progress_base + 1);
    return root_a == root_b;
}

struct DiffItem {
    uint160_t addr;
    DiffAccountSide a;
    DiffAccountSide b;
};

static ERL_NIF_TERM
account_map_list_difference_raw(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[])
{
    accountmap *am_a;
    accountmap *am_b;

    if (argc != 2) return enif_make_badarg(env);
    if (!enif_get_resource(env, argv[0], accountmap_type, (void **)&am_a)) return enif_make_badarg(env);
    if (!enif_get_resource(env, argv[1], accountmap_type, (void **)&am_b)) return enif_make_badarg(env);

    if (am_a->shared == am_b->shared) {
        return enif_make_list(env, 0);
    }

    std::vector<DiffItem> diffs;
    std::unordered_set<uint160_t> key_set;

    {
        DualAccountMapLock map_lock(am_a->shared, am_b->shared);

        for (auto &entry : am_a->shared->accounts) {
            key_set.insert(entry.first);
        }
        for (auto &entry : am_b->shared->accounts) {
            key_set.insert(entry.first);
        }

        std::vector<uint160_t> keys(key_set.begin(), key_set.end());
        std::sort(keys.begin(), keys.end());

        size_t i = 0;
        for (auto &addr : keys) {
            i++;
            auto it_a = am_a->shared->accounts.find(addr);
            auto it_b = am_b->shared->accounts.find(addr);
            bool in_a = it_a != am_a->shared->accounts.end();
            bool in_b = it_b != am_b->shared->accounts.end();

            if (in_a && in_b && entries_equal(env, it_a->second, it_b->second, i)) {
                nif_loop_progress(env, i);
                continue;
            }

            DiffItem item;
            item.addr = addr;
            if (in_a) {
                snapshot_side(it_a->second, item.a);
            }
            if (in_b) {
                snapshot_side(it_b->second, item.b);
            }
            diffs.push_back(std::move(item));
            nif_loop_progress(env, i);
        }
    }

    ERL_NIF_TERM list = enif_make_list(env, 0);
    size_t j = 0;
    for (auto &item : diffs) {
        j++;
        ERL_NIF_TERM addr_term = make_binary(env, (uint8_t *)item.addr.value, 20);
        ERL_NIF_TERM side_a = diff_side_to_term(env, item.a);
        ERL_NIF_TERM side_b = diff_side_to_term(env, item.b);
        ERL_NIF_TERM pair = enif_make_tuple2(env, side_a, side_b);
        ERL_NIF_TERM triple = enif_make_tuple2(env, addr_term, pair);
        list = enif_make_list_cell(env, triple, list);
        release_snapshot_side(item.a);
        release_snapshot_side(item.b);
        nif_loop_progress(env, j);
    }

    return list;
}

static ERL_NIF_TERM diff_side_fields_to_term(ErlNifEnv *env, DiffAccountSide &side)
{
    if (!side.present) {
        return make_atom(env, "nil");
    }
    ERL_NIF_TERM nonce = enif_make_uint64(env, side.nonce);
    ERL_NIF_TERM balance = balance_to_term(env, side.balance);
    ERL_NIF_TERM code = code_to_term(env, side.code);
    return enif_make_tuple3(env, nonce, balance, code);
}

static merkletree *storage_for_diff_side(DiffAccountSide &side, merkletree **temp_out)
{
    *temp_out = nullptr;
    if (!side.present) {
        return empty_storage_tree;
    }
    if (side.storage != nullptr) {
        return side.storage;
    }
    if (!side.compact_storage || side.compact_storage->slots.empty()) {
        return empty_storage_tree;
    }
    merkletree *mt = alloc_merkletree_resource();
    *temp_out = mt;
    {
        Lock lock(mt);
        for (auto &slot : side.compact_storage->slots) {
            mt->shared_state->tree.insert_item(slot.key, slot.value);
        }
    }
    return mt;
}

static void release_temp_storage(merkletree *temp)
{
    if (temp != nullptr) {
        enif_release_resource(temp);
    }
}

static ERL_NIF_TERM build_storage_diff_list(ErlNifEnv *env, DiffAccountSide &side_a,
        DiffAccountSide &side_b, size_t progress_base)
{
    merkletree *temp_a = nullptr;
    merkletree *temp_b = nullptr;
    merkletree *mt_a = storage_for_diff_side(side_a, &temp_a);
    merkletree *mt_b = storage_for_diff_side(side_b, &temp_b);

    if (mt_a == mt_b) {
        release_temp_storage(temp_a);
        release_temp_storage(temp_b);
        return enif_make_list(env, 0);
    }

    SharedState *s1 = mt_a->shared_state;
    SharedState *s2 = mt_b->shared_state;
    if (s1 == s2) {
        release_temp_storage(temp_a);
        release_temp_storage(temp_b);
        return enif_make_list(env, 0);
    }

    SharedStateLock state_lock(s1, s2);

    Tree output;
    s1->tree.difference(s2->tree, output);
    s2->tree.difference(s1->tree, output);

    ERL_NIF_TERM list = enif_make_list(env, 0);
    size_t i = 0;
    output.each([&](pair_t &pair) {
        i++;
        ERL_NIF_TERM key_term = make_binary(env, pair.key.data(), pair.key.size());

        auto pair1 = s1->tree.get_item(pair);
        auto pair2 = s2->tree.get_item(pair);

        ERL_NIF_TERM value1_term = pair1 == nullptr ? make_atom(env, "nil") :
            make_binary(env, pair1->value.data(), 32);
        ERL_NIF_TERM value2_term = pair2 == nullptr ? make_atom(env, "nil") :
            make_binary(env, pair2->value.data(), 32);
        ERL_NIF_TERM values = enif_make_tuple2(env, value1_term, value2_term);
        ERL_NIF_TERM item = enif_make_tuple2(env, key_term, values);
        list = enif_make_list_cell(env, item, list);
        nif_loop_progress(env, progress_base + i);
    });

    release_temp_storage(temp_a);
    release_temp_storage(temp_b);
    return list;
}

static ERL_NIF_TERM
account_map_difference_full(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[])
{
    accountmap *am_a;
    accountmap *am_b;

    if (argc != 2) return enif_make_badarg(env);
    if (!enif_get_resource(env, argv[0], accountmap_type, (void **)&am_a)) return enif_make_badarg(env);
    if (!enif_get_resource(env, argv[1], accountmap_type, (void **)&am_b)) return enif_make_badarg(env);

    if (am_a->shared == am_b->shared) {
        return enif_make_list(env, 0);
    }

    std::vector<DiffItem> diffs;
    std::unordered_set<uint160_t> key_set;

    {
        DualAccountMapLock map_lock(am_a->shared, am_b->shared);

        for (auto &entry : am_a->shared->accounts) {
            key_set.insert(entry.first);
        }
        for (auto &entry : am_b->shared->accounts) {
            key_set.insert(entry.first);
        }

        std::vector<uint160_t> keys(key_set.begin(), key_set.end());
        std::sort(keys.begin(), keys.end());

        size_t i = 0;
        for (auto &addr : keys) {
            i++;
            auto it_a = am_a->shared->accounts.find(addr);
            auto it_b = am_b->shared->accounts.find(addr);
            bool in_a = it_a != am_a->shared->accounts.end();
            bool in_b = it_b != am_b->shared->accounts.end();

            if (in_a && in_b && entries_equal(env, it_a->second, it_b->second, i)) {
                nif_loop_progress(env, i);
                continue;
            }

            DiffItem item;
            item.addr = addr;
            if (in_a) {
                snapshot_side(it_a->second, item.a);
            }
            if (in_b) {
                snapshot_side(it_b->second, item.b);
            }
            diffs.push_back(std::move(item));
            nif_loop_progress(env, i);
        }
    }

    ERL_NIF_TERM list = enif_make_list(env, 0);
    size_t j = 0;
    for (auto &item : diffs) {
        j++;
        ERL_NIF_TERM addr_term = make_binary(env, (uint8_t *)item.addr.value, 20);
        ERL_NIF_TERM side_a = diff_side_fields_to_term(env, item.a);
        ERL_NIF_TERM side_b = diff_side_fields_to_term(env, item.b);
        ERL_NIF_TERM storage_diff = build_storage_diff_list(env, item.a, item.b, j * 1000);
        ERL_NIF_TERM quad = enif_make_tuple4(env, addr_term, side_a, side_b, storage_diff);
        list = enif_make_list_cell(env, quad, list);
        release_snapshot_side(item.a);
        release_snapshot_side(item.b);
        nif_loop_progress(env, j);
    }

    locked_states->try_reclaim_orphans();
    return list;
}

static bool map_get_atom(ErlNifEnv *env, ERL_NIF_TERM map, const char *key, ERL_NIF_TERM &out);

static bool term_is_nil(ErlNifEnv *env, ERL_NIF_TERM term)
{
    if (!enif_is_atom(env, term)) {
        return false;
    }
    char atom[16];
    return enif_get_atom(env, term, atom, sizeof(atom), ERL_NIF_LATIN1) &&
        strcmp(atom, "nil") == 0;
}

static bool balance_equals_term(ErlNifEnv *env, const uint256_t &actual, ERL_NIF_TERM term)
{
    uint256_t expected;
    if (!get_balance_uint256(env, term, expected)) {
        return false;
    }
    return expected == actual;
}

static bool code_equals_term(ErlNifEnv *env, const bin_t &actual, ERL_NIF_TERM term)
{
    bin_t expected;
    if (!get_code(env, term, expected)) {
        return false;
    }
    return expected == actual;
}

static bool get_storage_value_from_term(ErlNifEnv *env, ERL_NIF_TERM term, uint256_t &out)
{
    memset(out.value, 0, sizeof(out.value));
    if (term_is_nil(env, term)) {
        return true;
    }
    ErlNifBinary bin;
    if (!enif_inspect_binary(env, term, &bin) || bin.size != 32) {
        return false;
    }
    memcpy(out.value, bin.data, 32);
    return true;
}

static bool storage_values_equal(ErlNifEnv *env, ERL_NIF_TERM expected_term, const uint256_t &actual)
{
    uint256_t expected;
    if (!get_storage_value_from_term(env, expected_term, expected)) {
        return false;
    }
    return expected == actual;
}

static uint256_t read_storage_slot(merkletree *mt, const bin_t &key)
{
    Lock lock(mt);
    bin_t lookup = key;
    pair_t *pair = mt->shared_state->tree.get_item(std::move(lookup));
    return pair == nullptr ? uint256_t() : pair->value;
}

static merkletree *write_storage_slot(AccountEntry &entry, const bin_t &key, const uint256_t &value)
{
    merkletree *mt = materialize_storage(entry);
    enif_mutex_lock(mt->shared_state->mtx);
    if (!make_writeable_locked(mt)) {
        enif_mutex_unlock(mt->shared_state->mtx);
        return nullptr;
    }
    bin_t key_copy = key;
    uint256_t value_copy = value;
    mt->shared_state->tree.insert_item(key_copy, value_copy);
    enif_mutex_unlock(mt->shared_state->mtx);
    entry.compact_storage.reset();
    return mt;
}

static ERL_NIF_TERM make_apply_error(ErlNifEnv *env, const char *reason)
{
    return enif_make_tuple2(env, make_atom(env, "error"), make_atom(env, reason));
}

static AccountEntry &ensure_account_entry(SharedAccountMap *shared, const uint160_t &addr)
{
    auto it = shared->accounts.find(addr);
    if (it == shared->accounts.end()) {
        AccountEntry entry;
        entry.storage = alloc_merkletree_resource();
        keep_storage_in_map(entry.storage);
        enif_release_resource(entry.storage);
        shared->accounts[addr] = std::move(entry);
        return shared->accounts[addr];
    }
    return it->second;
}

static bool apply_field_delta(ErlNifEnv *env, AccountEntry &entry, const char *field,
        ERL_NIF_TERM delta_term)
{
    const ERL_NIF_TERM *elems;
    int arity;
    if (!enif_get_tuple(env, delta_term, &arity, &elems) || arity != 2) {
        return false;
    }

    if (strcmp(field, "nonce") == 0) {
        ErlNifUInt64 expected, new_val;
        if (!enif_get_uint64(env, elems[0], &expected) ||
            !enif_get_uint64(env, elems[1], &new_val)) {
            return false;
        }
        if (entry.nonce != (uint64_t)expected) {
            return false;
        }
        entry.nonce = (uint64_t)new_val;
        return true;
    }

    if (strcmp(field, "balance") == 0) {
        if (!balance_equals_term(env, entry.balance, elems[0])) {
            return false;
        }
        if (!get_balance_uint256(env, elems[1], entry.balance)) {
            return false;
        }
        return true;
    }

    if (strcmp(field, "code") == 0) {
        if (!code_equals_term(env, entry.code, elems[0])) {
            return false;
        }
        if (!get_code(env, elems[1], entry.code)) {
            return false;
        }
        return true;
    }

    return true;
}

static bool apply_storage_delta(ErlNifEnv *env, AccountEntry &entry, ERL_NIF_TERM state_map)
{
    if (!enif_is_map(env, state_map)) {
        return false;
    }

    ErlNifMapIterator iter;
    enif_map_iterator_create(env, state_map, &iter, ERL_NIF_MAP_ITERATOR_FIRST);

    ERL_NIF_TERM slot_key, slot_delta;
    while (enif_map_iterator_get_pair(env, &iter, &slot_key, &slot_delta)) {
        ErlNifBinary key_bin;
        if (!enif_inspect_binary(env, slot_key, &key_bin)) {
            enif_map_iterator_destroy(env, &iter);
            return false;
        }

        const ERL_NIF_TERM *delta_elems;
        int delta_arity;
        if (!enif_get_tuple(env, slot_delta, &delta_arity, &delta_elems) || delta_arity != 2) {
            enif_map_iterator_destroy(env, &iter);
            return false;
        }

        merkletree *mt = materialize_storage(entry);
        bin_t key(key_bin.data, key_bin.data + key_bin.size);
        uint256_t current = read_storage_slot(mt, key);
        if (!storage_values_equal(env, delta_elems[0], current)) {
            enif_map_iterator_destroy(env, &iter);
            return false;
        }

        uint256_t new_value;
        if (!get_storage_value_from_term(env, delta_elems[1], new_value)) {
            enif_map_iterator_destroy(env, &iter);
            return false;
        }

        if (write_storage_slot(entry, key, new_value) == nullptr) {
            enif_map_iterator_destroy(env, &iter);
            return false;
        }

        enif_map_iterator_next(env, &iter);
    }

    enif_map_iterator_destroy(env, &iter);
    return true;
}

static ERL_NIF_TERM
account_map_apply_difference(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[])
{
    accountmap *am;
    if (argc != 2) return enif_make_badarg(env);
    if (!enif_get_resource(env, argv[0], accountmap_type, (void **)&am)) return enif_make_badarg(env);
    if (!enif_is_list(env, argv[1])) return enif_make_badarg(env);

    AccountMapLock lock(am);
    if (!make_writeable_accountmap(am)) return enif_make_badarg(env);

    AccountHashCtx hash_ctx;
    size_t i = 0;
    ERL_NIF_TERM head, tail = argv[1];

    while (enif_get_list_cell(env, tail, &head, &tail)) {
        i++;
        const ERL_NIF_TERM *elems;
        int arity;
        if (!enif_get_tuple(env, head, &arity, &elems) || arity != 2) {
            return enif_make_badarg(env);
        }

        uint160_t addr;
        if (!get_address(env, elems[0], addr)) {
            return enif_make_badarg(env);
        }
        if (!enif_is_map(env, elems[1])) {
            return enif_make_badarg(env);
        }

        AccountEntry &entry = ensure_account_entry(am->shared, addr);
        ERL_NIF_TERM report = elems[1];

        ERL_NIF_TERM state_term;
        if (map_get_atom(env, report, "state", state_term)) {
            if (!apply_storage_delta(env, entry, state_term)) {
                return make_apply_error(env, "mismatch");
            }
        }

        static const char *fields[] = {"nonce", "balance", "code", nullptr};
        for (int f = 0; fields[f] != nullptr; f++) {
            ERL_NIF_TERM delta_term;
            if (map_get_atom(env, report, fields[f], delta_term)) {
                if (!apply_field_delta(env, entry, fields[f], delta_term)) {
                    return make_apply_error(env, "mismatch");
                }
            }
        }

        update_state_trie_for_entry(am->shared, addr, entry, hash_ctx);
        nif_loop_progress(env, i);
    }

    locked_states->try_reclaim_orphans();
    return argv[0];
}

struct UncompactLoopScratch {
    AccountHashCtx hash_ctx;
    bin_t code_buf;
};

struct ParsedCompactAccount {
    AccountEntry entry;
    bool has_compact_root_hash;
    uint256_t compact_root_hash;
    bool has_compact_code_hash;
    uint256_t compact_code_hash;
};

struct PendingStateItem {
    uint160_t addr;
    uint256_t hash;
};

static bool map_get_atom(ErlNifEnv *env, ERL_NIF_TERM map, const char *key, ERL_NIF_TERM &out)
{
    ERL_NIF_TERM key_term;
    if (!enif_make_existing_atom(env, key, &key_term, ERL_NIF_LATIN1)) {
        return false;
    }
    return enif_get_map_value(env, map, key_term, &out);
}

static bool parse_compact_storage(ErlNifEnv *env, ERL_NIF_TERM storage_term,
        AccountEntry &entry)
{
    entry.storage = nullptr;
    entry.compact_storage.reset();

    merkletree *existing;
    if (enif_get_resource(env, storage_term, merkletree_type, (void **)&existing)) {
        entry.storage = existing;
        return true;
    }

    if (enif_is_atom(env, storage_term)) {
        char atom[16];
        if (enif_get_atom(env, storage_term, atom, sizeof(atom), ERL_NIF_LATIN1) &&
            strcmp(atom, "nil") == 0) {
            return true;
        }
        return false;
    }

    entry.compact_storage = std::make_unique<CompactStorage>();

    const ERL_NIF_TERM *elems;
    int arity;
    if (enif_get_tuple(env, storage_term, &arity, &elems) && arity == 3) {
        char atom[64];
        if (enif_get_atom(env, elems[0], atom, sizeof(atom), ERL_NIF_LATIN1) &&
            (strcmp(atom, "MapMerkleTree") == 0 ||
             strcmp(atom, "Elixir.MapMerkleTree") == 0)) {
            ERL_NIF_TERM key, value;
            ErlNifMapIterator iter;
            enif_map_iterator_create(env, elems[2], &iter, ERL_NIF_MAP_ITERATOR_FIRST);

            while (enif_map_iterator_get_pair(env, &iter, &key, &value)) {
                ErlNifBinary key_binary, value_binary;
                if (!enif_inspect_binary(env, key, &key_binary) ||
                    !enif_inspect_binary(env, value, &value_binary)) {
                    enif_map_iterator_destroy(env, &iter);
                    return false;
                }
                StorageSlot slot;
                if (!decode_storage_slot(key_binary, value_binary, slot)) {
                    enif_map_iterator_destroy(env, &iter);
                    return false;
                }
                entry.compact_storage->slots.push_back(std::move(slot));
                enif_map_iterator_next(env, &iter);
            }
            enif_map_iterator_destroy(env, &iter);
            return true;
        }
    }

    if (enif_is_list(env, storage_term)) {
        ERL_NIF_TERM head, tail = storage_term;

        while (enif_get_list_cell(env, tail, &head, &tail)) {
            const ERL_NIF_TERM *pair_elems;
            int pair_arity;
            if (!enif_get_tuple(env, head, &pair_arity, &pair_elems) || pair_arity != 2) {
                return false;
            }
            ErlNifBinary key_binary, value_binary;
            if (!enif_inspect_binary(env, pair_elems[0], &key_binary) ||
                !enif_inspect_binary(env, pair_elems[1], &value_binary)) {
                return false;
            }
            StorageSlot slot;
            if (!decode_storage_slot(key_binary, value_binary, slot)) {
                return false;
            }
            entry.compact_storage->slots.push_back(std::move(slot));
        }
        return true;
    }

    return false;
}

static bool parse_compact_account(ErlNifEnv *env, ERL_NIF_TERM account_term,
        ParsedCompactAccount &out, bin_t &code_buf)
{
    out.has_compact_root_hash = false;
    out.has_compact_code_hash = false;
    if (!enif_is_map(env, account_term)) {
        return false;
    }

    ERL_NIF_TERM nonce_term, balance_term, storage_term, code_term;
    if (!map_get_atom(env, account_term, "nonce", nonce_term) ||
        !map_get_atom(env, account_term, "balance", balance_term) ||
        !map_get_atom(env, account_term, "storage_root", storage_term) ||
        !map_get_atom(env, account_term, "code", code_term)) {
        return false;
    }

    ERL_NIF_TERM root_hash_term;
    if (map_get_atom(env, account_term, "root_hash", root_hash_term)) {
        ErlNifBinary root_bin;
        if (!enif_inspect_binary(env, root_hash_term, &root_bin) || root_bin.size != 32) {
            return false;
        }
        out.compact_root_hash = (char*)root_bin.data;
        out.has_compact_root_hash = true;
    }

    ERL_NIF_TERM code_hash_term;
    if (map_get_atom(env, account_term, "code_hash", code_hash_term)) {
        ErlNifBinary code_hash_bin;
        if (!enif_inspect_binary(env, code_hash_term, &code_hash_bin) || code_hash_bin.size != 32) {
            return false;
        }
        out.compact_code_hash = (char*)code_hash_bin.data;
        out.has_compact_code_hash = true;
    }

    ErlNifUInt64 nonce;
    if (!enif_get_uint64(env, nonce_term, &nonce)) {
        return false;
    }
    if (!get_balance_uint256(env, balance_term, out.entry.balance)) {
        return false;
    }
    if (!get_code(env, code_term, code_buf)) {
        return false;
    }
    out.entry.code = std::move(code_buf);

    out.entry.nonce = (uint64_t)nonce;
    return parse_compact_storage(env, storage_term, out.entry);
}

static ERL_NIF_TERM uncompact_state_fail(ErlNifEnv *env, ErlNifMapIterator *iter,
        accountmap *am, merkletree *state_store)
{
    if (iter) {
        enif_map_iterator_destroy(env, iter);
    }
    if (am) {
        enif_release_resource(am);
    }
    if (state_store) {
        enif_release_resource(state_store);
    }
    return enif_make_badarg(env);
}

static void batch_insert_state_items(merkletree *state_store, std::vector<PendingStateItem> &items)
{
    if (items.empty()) {
        return;
    }
    std::sort(items.begin(), items.end(), [](const PendingStateItem &a, const PendingStateItem &b) {
        return memcmp(a.addr.value, b.addr.value, 20) < 0;
    });
    Lock lock(state_store);
    bin_t addr_key;
    for (auto &item : items) {
        addr_key.assign(item.addr.value, item.addr.value + 20);
        state_store->shared_state->tree.insert_item(addr_key, item.hash);
    }
}

static bool append_uncompacted_account(ErlNifEnv *env, accountmap *am, AccountHashCtx &hash_ctx,
        std::vector<PendingStateItem> &pending_state, const uint160_t &addr, AccountEntry &entry,
        const uint256_t *storage_root_override, const uint256_t *code_hash_override, size_t i)
{
    if (entry.storage == nullptr) {
        if (storage_root_override == nullptr) {
            // Fresh materialize: alloc ownership transfers with the entry.
            materialize_storage(entry);
        }
    } else if (entry.compact_storage == nullptr) {
        // Shared/copied pointer from another map or Elixir term: take a map ref.
        keep_storage_in_map(entry.storage);
    }
    uint256_t account_hash;
    if (!hash_ctx.compute(entry, storage_root_override, code_hash_override, account_hash)) {
        return false;
    }
    am->shared->accounts[addr] = std::move(entry);
    pending_state.push_back({addr, account_hash});
    nif_loop_progress(env, i);
    return true;
}

static ERL_NIF_TERM
account_map_uncompact_state(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[])
{
    if (argc != 1) return enif_make_badarg(env);

    accountmap *input_am = nullptr;
    bool from_resource = enif_get_resource(env, argv[0], accountmap_type, (void **)&input_am);

    accountmap *am = (accountmap*)enif_alloc_resource(accountmap_type, sizeof(accountmap));
    am->shared = new SharedAccountMap();

    size_t expected = 0;
    if (from_resource) {
        AccountMapLock lock(input_am);
        expected = input_am->shared->accounts.size();
    } else if (enif_is_map(env, argv[0])) {
        if (!enif_get_map_size(env, argv[0], &expected)) {
            enif_release_resource(am);
            return enif_make_badarg(env);
        }
    } else {
        enif_release_resource(am);
        return enif_make_badarg(env);
    }

    am->shared->accounts.reserve(expected);
    std::vector<PendingStateItem> pending_state;
    pending_state.reserve(expected);
    UncompactLoopScratch scratch;

    size_t i = 0;

    if (from_resource) {
        AccountMapLock lock(input_am);
        for (auto &kv : input_am->shared->accounts) {
            i++;
            AccountEntry entry = kv.second;
            if (!append_uncompacted_account(env, am, scratch.hash_ctx, pending_state, kv.first, entry,
                    nullptr, nullptr, i)) {
                return uncompact_state_fail(env, nullptr, am, nullptr);
            }
        }
    } else {
        ERL_NIF_TERM key, value;
        ErlNifMapIterator iter;
        enif_map_iterator_create(env, argv[0], &iter, ERL_NIF_MAP_ITERATOR_FIRST);

        while (enif_map_iterator_get_pair(env, &iter, &key, &value)) {
            i++;
            uint160_t addr;
            if (!get_address(env, key, addr)) {
                return uncompact_state_fail(env, &iter, am, nullptr);
            }

            ParsedCompactAccount parsed;
            if (!parse_compact_account(env, value, parsed, scratch.code_buf)) {
                return uncompact_state_fail(env, &iter, am, nullptr);
            }

            const uint256_t *storage_root_override =
                parsed.has_compact_root_hash ? &parsed.compact_root_hash : nullptr;
            const uint256_t *code_hash_override =
                parsed.has_compact_code_hash ? &parsed.compact_code_hash : nullptr;
            if (!append_uncompacted_account(env, am, scratch.hash_ctx, pending_state, addr,
                    parsed.entry, storage_root_override, code_hash_override, i)) {
                return uncompact_state_fail(env, &iter, am, nullptr);
            }

            enif_map_iterator_next(env, &iter);
        }
        enif_map_iterator_destroy(env, &iter);
    }

    batch_insert_state_items(am->shared->state_trie, pending_state);

    uint256_t state_root;
    {
        Lock lock(am->shared->state_trie);
        state_root = am->shared->state_trie->shared_state->tree.root_hash();
    }

    ERL_NIF_TERM am_term = enif_make_resource(env, am);
    enif_release_resource(am);
    ERL_NIF_TERM hash_term = make_binary(env, state_root.data(), 32);
    return enif_make_tuple2(env, am_term, hash_term);
}

static void
destruct_accountmap_type(ErlNifEnv* /*env*/, void *arg)
{
    accountmap *am = (accountmap *)arg;
    if (am->shared) {
        AccountMapLock lock(am);
        destroy_shared_accountmap(am, lock);
    }
}

static void
destruct_merkletree_type(ErlNifEnv* /*env*/, void *arg)
{
    merkletree *mt = (merkletree *) arg;
    STAT(resources--);
    locked_states->leave_lock(mt);
}


static int
on_load(ErlNifEnv* env, void** /*priv*/, ERL_NIF_TERM /*info*/)
{
    ErlNifResourceType *rt;

    rt = enif_open_resource_type(env, "merkletree_nif", "merkletree_type",
            destruct_merkletree_type, ERL_NIF_RT_CREATE, NULL);
    if(!rt) return -1;
    merkletree_type = rt;

    rt = enif_open_resource_type(env, "merkletree_nif", "accountmap_type",
            destruct_accountmap_type, ERL_NIF_RT_CREATE, NULL);
    if(!rt) return -1;
    accountmap_type = rt;

    locked_states = new LockedStates();
    stats_mutex = enif_mutex_create((char*)"stats_mutex");
    sha((const uint8_t*)"", 0, empty_code_hash.value);
    empty_storage_tree = alloc_merkletree_resource();
    enif_keep_resource(empty_storage_tree);
    return 0;
}

static int on_reload(ErlNifEnv* /*env*/, void** /*priv_data*/, ERL_NIF_TERM /*load_info*/)
{
    return 0;
}

static int on_upgrade(ErlNifEnv* /*env*/, void** /*priv*/, void** /*old_priv_data*/, ERL_NIF_TERM /*load_info*/)
{
    return 0;
}

static ErlNifFunc nif_funcs[] = {
    {"new", 0, merkletree_new, 0},
    {"insert_item_raw", 3, merkletree_insert_item, 0},
    {"get_item", 2, merkletree_get_item, 0},
    {"get_range_raw", 3, merkletree_get_range, 0},
    {"get_proofs_raw", 2, merkletree_get_proofs, ERL_NIF_DIRTY_JOB_CPU_BOUND},
    {"difference_raw", 2, merkletree_difference, ERL_NIF_DIRTY_JOB_CPU_BOUND},
    {"lock", 1, merkletree_lock, ERL_NIF_DIRTY_JOB_CPU_BOUND},
    {"to_list", 1, merkletree_to_list, ERL_NIF_DIRTY_JOB_CPU_BOUND},
    {"import_map", 2, merkletree_import_map, ERL_NIF_DIRTY_JOB_CPU_BOUND},
    {"root_hash", 1, merkletree_root_hash, 0},
    {"hash", 1, merkletree_hash, 0},
    {"root_hashes_raw", 1, merkletree_root_hashes, 0},
    {"bucket_count", 1, merkletree_bucket_count, 0},
    {"size", 1, merkletree_size, 0},
    {"clone", 1, merkletree_clone, ERL_NIF_DIRTY_JOB_CPU_BOUND},
    {"count_zeros", 1, merkletree_count_zeros, ERL_NIF_DIRTY_JOB_CPU_BOUND},
    {"struct_sizes_raw", 0, merkletree_struct_sizes, 0},
    {"memory_stats_raw", 1, merkletree_memory_stats, ERL_NIF_DIRTY_JOB_CPU_BOUND},
    {"malloc_info_raw", 0, merkletree_malloc_info, ERL_NIF_DIRTY_JOB_IO_BOUND},
    {"nif_stats_raw", 0, merkletree_nif_stats, 0},
    {"account_map_new", 0, account_map_new, 0},
    {"account_map_clone", 1, account_map_clone, ERL_NIF_DIRTY_JOB_CPU_BOUND},
    {"account_map_clone_lazy", 1, account_map_clone_lazy, ERL_NIF_DIRTY_JOB_CPU_BOUND},
    {"account_map_lock", 1, account_map_lock, ERL_NIF_DIRTY_JOB_CPU_BOUND},
    {"account_map_get", 2, account_map_get, 0},
    {"account_map_put", 6, account_map_put, 0},
    {"account_map_delete", 2, account_map_delete, 0},
    {"account_map_root_hash", 1, account_map_root_hash, 0},
    {"account_map_state_trie", 1, account_map_state_trie, 0},
    {"account_map_size", 1, account_map_size, 0},
    {"account_map_to_list", 1, account_map_to_list, ERL_NIF_DIRTY_JOB_CPU_BOUND},
    {"account_map_list_difference_raw", 2, account_map_list_difference_raw, ERL_NIF_DIRTY_JOB_CPU_BOUND},
    {"account_map_difference_full", 2, account_map_difference_full, ERL_NIF_DIRTY_JOB_CPU_BOUND},
    {"account_map_apply_difference", 2, account_map_apply_difference, ERL_NIF_DIRTY_JOB_CPU_BOUND},
    {"account_map_uncompact_state", 1, account_map_uncompact_state, ERL_NIF_DIRTY_JOB_CPU_BOUND},
};

// ERL_NIF_INIT(merkletree_nif, nif_funcs, on_load, on_reload, on_upgrade, NULL);
ERL_NIF_INIT(Elixir.CMerkleTree, nif_funcs, on_load, on_reload, on_upgrade, NULL)

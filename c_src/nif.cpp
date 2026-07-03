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
#include <cstring>
#include <cstdio>
#include <unordered_map>
#include <vector>
#ifdef __GLIBC__
#include <malloc.h>
#endif

static constexpr size_t kNifTimesliceInterval = 512;
static constexpr size_t kAccountMapCowProgressInterval = 1024;

static void nif_loop_progress(ErlNifEnv *env, size_t i)
{
    if (env && i > 0 && (i % kNifTimesliceInterval) == 0) {
        (void)enif_consume_timeslice(env, 1);
    }
}

static void accountmap_cow_copy_progress(ErlNifEnv *env, size_t i)
{
    if (env && i > 0 && (i % kAccountMapCowProgressInterval) == 0) {
        (void)enif_consume_timeslice(env, 1);
    }
}

static void print(const char *msg);
static ErlNifResourceType *merkletree_type = NULL;
static ErlNifResourceType *accountmap_type = NULL;
static ErlNifMutex *stats_mutex = NULL;
static ERL_NIF_TERM make_atom(ErlNifEnv *env, const char *atom_name);
static ERL_NIF_TERM make_binary(ErlNifEnv *env, uint8_t *data, size_t size);
static volatile int shared_states = 0;
static volatile int resources = 0;
static int locked_states_cnt = 0;


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
    Tree tree;
    SharedState() : tree() {
        mtx = enif_mutex_create((char*)"merkletree_mutex");
        has_clone = 0;
        STAT(shared_states++);
        print("CREATE");
    }

    SharedState(SharedState &other) : tree(other.tree) {
        mtx = enif_mutex_create((char*)"merkletree_mutex");
        has_clone = 0;
        STAT(shared_states++);
        print("CLONE");
    }

    ~SharedState() {
        STAT(shared_states--);
        print("DESTROY");
        enif_mutex_destroy(mtx);
    }
};

struct  merkletree {
    bool locked;
    SharedState *shared_state;
};

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

static void destroy_shared_state(merkletree *mt, Lock &lock);
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

struct AccountEntry {
    uint64_t nonce;
    uint256_t balance;
    merkletree *storage;
    bin_t code;
};

class SharedAccountMap {
public:
    ErlNifMutex *mtx;
    int has_clone;
    std::unordered_map<uint160_t, AccountEntry> accounts;

    SharedAccountMap() : has_clone(0) {
        mtx = enif_mutex_create((char*)"accountmap_mutex");
    }

    ~SharedAccountMap() {
        for (auto &entry : accounts) {
            release_storage_from_map(entry.second.storage);
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

static SharedAccountMap *cow_copy_accountmap(SharedAccountMap *other, ErlNifEnv *env)
{
    SharedAccountMap *copy = new SharedAccountMap();
    copy->accounts = other->accounts;
    size_t i = 0;
    for (auto &entry : copy->accounts) {
        keep_storage_in_map(entry.second.storage);
        i++;
        accountmap_cow_copy_progress(env, i);
    }
    return copy;
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

static bool get_address(ErlNifEnv *env, ERL_NIF_TERM term, uint160_t &out)
{
    ErlNifBinary bin;
    if (!enif_inspect_binary(env, term, &bin) || bin.size != 20) {
        return false;
    }
    out = uint160_t(bin.data);
    return true;
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
    return false;
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

static bool make_writeable_accountmap(ErlNifEnv *env, accountmap *am)
{
    if (am->shared->has_clone > 0) {
        am->shared->has_clone -= 1;
        am->shared = cow_copy_accountmap(am->shared, env);
    }
    return true;
}

static void destroy_shared_accountmap(accountmap *am, AccountMapLock &lock)
{
    if (am->shared->has_clone == 0) {
        lock.unlock();
        delete am->shared;
    } else {
        am->shared->has_clone -= 1;
    }
    am->shared = NULL;
}

class LockedStates {
public:
    std::unordered_map<uint256_t, SharedState*> states;
    ErlNifMutex *mtx;
    LockedStates() {
        mtx = enif_mutex_create((char*)"locked_states_mutex");
    }

    ~LockedStates() {
        enif_mutex_destroy(mtx);
    }

    void enter_lock(merkletree *mt) {
        locked_states_cnt = states.size();
        print("ENTER_LOCK");

        enif_mutex_lock(mtx);
        Lock lock(mt);

        mt->locked = true;
        uint256_t root_hash = mt->shared_state->tree.root_hash();
        auto it = states.find(root_hash);
        if (it != states.end()) {
            if (it->second != mt->shared_state) {
                destroy_shared_state(mt, lock);
                enif_mutex_lock(it->second->mtx);
                mt->shared_state = it->second;
                mt->shared_state->has_clone += 1;
                enif_mutex_unlock(it->second->mtx);
            }
        } else {
            states[root_hash] = mt->shared_state;
        }

        lock.unlock();
        enif_mutex_unlock(mtx);
    }

    void leave_lock(merkletree *mt) {
        locked_states_cnt = states.size();
        print("LEAVE_LOCK");

        enif_mutex_lock(mtx);
        Lock lock(mt);

        if (mt->shared_state->has_clone == 0) {
            uint256_t root_hash = mt->shared_state->tree.root_hash();

            auto it = states.find(root_hash);
            if (it != states.end() && it->second == mt->shared_state) {
                states.erase(it);
            }
        }

        destroy_shared_state(mt, lock);
        lock.unlock();
        enif_mutex_unlock(mtx);
    }
};

static LockedStates* locked_states;

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
    merkletree *mt = (merkletree*)enif_alloc_resource(merkletree_type, sizeof(merkletree));
    STAT(resources++);
    mt->shared_state = new SharedState();
    mt->locked = false;
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


bool make_writeable(merkletree *mt)
{
    if (mt->locked) return false;

    if (mt->shared_state->has_clone > 0) {
        mt->shared_state->has_clone -= 1;
        mt->shared_state = new SharedState(*mt->shared_state);
        print("CREATING (UNCLONING)");
    }
    return true;
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
    if (value_binary.size != 32) return enif_make_badarg(env);

    Lock lock(mt);
    if (!make_writeable(mt)) return enif_make_badarg(env);

    bin_t key;
    key.insert(key.end(), key_binary.data, key_binary.data + key_binary.size);
    uint256_t value = (char*)value_binary.data;
    mt->shared_state->tree.insert_item(key, value);
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

    if (&mt1->shared_state->tree == &mt2->shared_state->tree) {
        return enif_make_list(env, 0);
    }

    /* Lock ordering by SharedState address to avoid deadlock when two schedulers
     * call difference_raw(A,B) vs difference_raw(B,A). */
    merkletree *first = mt1->shared_state < mt2->shared_state ? mt1 : mt2;
    merkletree *second = mt1->shared_state < mt2->shared_state ? mt2 : mt1;
    Lock lock1(first);
    Lock lock2(second);

    Tree output;
    first->shared_state->tree.difference(second->shared_state->tree, output);
    second->shared_state->tree.difference(first->shared_state->tree, output);

    ERL_NIF_TERM list = enif_make_list(env, 0);
    size_t i = 0;
    output.each([&](pair_t &pair) {
        i++;
        ERL_NIF_TERM key_term = make_binary(env, pair.key.data(), pair.key.size());

        auto pair1 = mt1->shared_state->tree.get_item(pair);
        auto pair2 = mt2->shared_state->tree.get_item(pair);

        ERL_NIF_TERM value1_term = pair1 == nullptr ? make_atom(env, "nil") : make_binary(env, pair1->value.data(), 32);
        ERL_NIF_TERM value2_term = pair2 == nullptr ? make_atom(env, "nil") : make_binary(env, pair2->value.data(), 32);
        ERL_NIF_TERM tuple = enif_make_tuple2(env, value1_term, value2_term);
        tuple = enif_make_tuple2(env, key_term, tuple);
        list = enif_make_list_cell(env, tuple, list);
        nif_loop_progress(env, i);
    });
    return list;
}

static ERL_NIF_TERM
merkletree_import_map(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[])
{
    merkletree *mt;

    if (argc != 2) return enif_make_badarg(env);
    if (!enif_get_resource(env, argv[0], merkletree_type, (void **) &mt)) return enif_make_badarg(env);
    if (!enif_is_map(env, argv[1])) return enif_make_badarg(env);

    Lock lock(mt);
    if (!make_writeable(mt)) return enif_make_badarg(env);

    ERL_NIF_TERM key, value;
    ErlNifMapIterator iter;
    enif_map_iterator_create(env, argv[1], &iter, ERL_NIF_MAP_ITERATOR_FIRST);

    size_t i = 0;
    while (enif_map_iterator_get_pair(env, &iter, &key, &value)) {
        i++;
        ErlNifBinary key_binary, value_binary;
        if (!enif_inspect_binary(env, key, &key_binary)) {
            goto import_badarg;
        }
        if (!enif_inspect_binary(env, value, &value_binary)) {
            goto import_badarg;
        }
        if (value_binary.size != 32) {
            goto import_badarg;
        }
        bin_t key;
        key.insert(key.end(), key_binary.data, key_binary.data + key_binary.size);
        uint256_t value = (char*)value_binary.data;
        mt->shared_state->tree.insert_item(key, value);
        enif_map_iterator_next(env, &iter);
        nif_loop_progress(env, i);
    }
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

    // Eagerly COW the SharedAccountMap and clone every storage trie so the fork is
    // writable (locked = false) while the cached parent stays frozen. Sharing the
    // parent's merkletree* resources would leave the fork's storage tries with
    // mt->locked == true, and make_writeable() would reject every storage write
    // (merkletree_insert_item returns badarg), breaking block sync.
    SharedAccountMap *new_shared = new SharedAccountMap();
    new_shared->accounts = am->shared->accounts;

    // Clone each unique parent storage trie once (accounts that shared a storage
    // trie in the parent keep sharing the single clone). ~SharedAccountMap releases
    // one resource ref per entry, so we keep one ref per entry here to match.
    std::unordered_map<merkletree*, merkletree*> storage_clones;
    size_t i = 0;
    for (auto &entry : new_shared->accounts) {
        i++;
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
    // Drop the creator refs (one per unique clone); the per-entry keeps above own
    // the resources now.
    for (auto &kv : storage_clones) {
        enif_release_resource(kv.second);
    }

    accountmap *clone = (accountmap*)enif_alloc_resource(accountmap_type, sizeof(accountmap));
    clone->shared = new_shared;
    ERL_NIF_TERM res = enif_make_resource(env, clone);
    enif_release_resource(clone);
    return res;
}

static ERL_NIF_TERM account_entry_to_term(ErlNifEnv *env, const AccountEntry &entry)
{
    ERL_NIF_TERM nonce = enif_make_uint64(env, entry.nonce);
    ERL_NIF_TERM balance = balance_to_term(env, entry.balance);
    ERL_NIF_TERM storage = enif_make_resource(env, entry.storage);
    ERL_NIF_TERM code = code_to_term(env, entry.code);
    return enif_make_tuple4(env, nonce, balance, storage, code);
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
    if (!make_writeable_accountmap(env, am)) return enif_make_badarg(env);

    auto it = am->shared->accounts.find(addr);
    if (it != am->shared->accounts.end()) {
        if (it->second.storage != storage) {
            release_storage_from_map(it->second.storage);
            keep_storage_in_map(storage);
        }
        it->second.nonce = (uint64_t)nonce;
        it->second.balance = balance;
        it->second.storage = storage;
        it->second.code = code;
    } else {
        keep_storage_in_map(storage);
        am->shared->accounts[addr] = AccountEntry{(uint64_t)nonce, balance, storage, code};
    }
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
    if (!make_writeable_accountmap(env, am)) return enif_make_badarg(env);

    auto it = am->shared->accounts.find(addr);
    if (it != am->shared->accounts.end()) {
        release_storage_from_map(it->second.storage);
        am->shared->accounts.erase(it);
    }
    return argv[0];
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

static void destroy_shared_state(merkletree *mt, Lock &lock) {
    if (mt->shared_state->has_clone == 0) {
        lock.unlock();
        delete(mt->shared_state);
    } else {
        mt->shared_state->has_clone -= 1;
    }
    mt->shared_state = NULL;
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
    {"lock", 1, merkletree_lock, 0},
    {"to_list", 1, merkletree_to_list, ERL_NIF_DIRTY_JOB_CPU_BOUND},
    {"import_map", 2, merkletree_import_map, ERL_NIF_DIRTY_JOB_CPU_BOUND},
    {"root_hash", 1, merkletree_root_hash, 0},
    {"hash", 1, merkletree_hash, 0},
    {"root_hashes_raw", 1, merkletree_root_hashes, 0},
    {"bucket_count", 1, merkletree_bucket_count, 0},
    {"size", 1, merkletree_size, 0},
    {"clone", 1, merkletree_clone, 0},
    {"count_zeros", 1, merkletree_count_zeros, ERL_NIF_DIRTY_JOB_CPU_BOUND},
    {"struct_sizes_raw", 0, merkletree_struct_sizes, 0},
    {"memory_stats_raw", 1, merkletree_memory_stats, ERL_NIF_DIRTY_JOB_CPU_BOUND},
    {"malloc_info_raw", 0, merkletree_malloc_info, ERL_NIF_DIRTY_JOB_IO_BOUND},
    {"account_map_new", 0, account_map_new, 0},
    {"account_map_clone", 1, account_map_clone, ERL_NIF_DIRTY_JOB_CPU_BOUND},
    {"account_map_get", 2, account_map_get, 0},
    {"account_map_put", 6, account_map_put, 0},
    {"account_map_delete", 2, account_map_delete, 0},
    {"account_map_size", 1, account_map_size, 0},
    {"account_map_to_list", 1, account_map_to_list, ERL_NIF_DIRTY_JOB_CPU_BOUND},
};

// ERL_NIF_INIT(merkletree_nif, nif_funcs, on_load, on_reload, on_upgrade, NULL);
ERL_NIF_INIT(Elixir.CMerkleTree, nif_funcs, on_load, on_reload, on_upgrade, NULL)

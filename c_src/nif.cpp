extern "C" {
#include <erl_nif.h>
#include "sha.h"
}

#include "merkletree.hpp"

static ErlNifResourceType *merkletree_type = NULL;
static volatile int ops = 0;
static volatile int shared_states = 0;
static volatile int resources = 0;

static void print(const char *msg) {
    if (ops++ % 10000 == 0) {
        fprintf(stderr, "%s [shared_states=%d] [resources=%d]\n", msg, shared_states, resources); fflush(stderr);
    }
}

class SharedState {
public:
    ErlNifMutex *mtx;
    int has_clone;
    Tree tree;
    SharedState() : tree() {
        mtx = enif_mutex_create((char*)"merkletree_mutex");
        has_clone = 0;
        shared_states++;
        print("CREATE");
    }

    SharedState(SharedState &other) : tree(other.tree) {
        mtx = enif_mutex_create((char*)"merkletree_mutex");
        has_clone = 0;
        shared_states++;
        print("CLONE");
    }

    ~SharedState() {
        shared_states--;
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
        enif_mutex_unlock(mtx);
        mtx = 0;
    }

    ~Lock() {
        if (mtx) {
            enif_mutex_unlock(mtx);
        }
    }
};

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
    ErlNifBinary blob;
    if (!enif_alloc_binary(size, &blob)) {
        return make_atom(env, "error");
    }
    memcpy(blob.data, data, size);
    ERL_NIF_TERM term = enif_make_binary(env, &blob);
    enif_release_binary(&blob);
    return term;
}


static ERL_NIF_TERM
merkletree_new(ErlNifEnv *env, int argc, const ERL_NIF_TERM[] /*argv[]*/)
{
    if (argc != 0) return enif_make_badarg(env);
    merkletree *mt = (merkletree*)enif_alloc_resource(merkletree_type, sizeof(merkletree));
    resources++;
    mt->shared_state = new SharedState();
    mt->locked = false;
    ERL_NIF_TERM res = enif_make_resource(env, mt);
    enif_release_resource(mt);
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
merkletree_clone(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[])
{
    merkletree *mt;
    if (argc != 1) return enif_make_badarg(env);
    if (!enif_get_resource(env, argv[0], merkletree_type, (void **) &mt)) return enif_make_badarg(env);

    Lock lock(mt);
    merkletree *clone = (merkletree*)enif_alloc_resource(merkletree_type, sizeof(merkletree));
    resources++;
    clone->shared_state = mt->shared_state;
    clone->locked = false;
    clone->shared_state->has_clone += 1;
    ERL_NIF_TERM res = enif_make_resource(env, clone);
    enif_release_resource(clone);
    return res;
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

static ERL_NIF_TERM
merkletree_get_item(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[])
{
    merkletree *mt;
    ErlNifBinary key_binary;

    if (argc != 2) return enif_make_badarg(env);
    if (!enif_get_resource(env, argv[0], merkletree_type, (void **) &mt)) return enif_make_badarg(env);
    Lock lock(mt);
    if (!enif_inspect_binary(env, argv[1], &key_binary)) return enif_make_badarg(env);

    bin_t key;
    key.insert(key.end(), key_binary.data, key_binary.data + key_binary.size);
    pair_t* pair = mt->shared_state->tree.get_item(std::move(key));
    enif_release_binary(&key_binary);


    if (pair == nullptr) {
        return make_atom(env, "nil");
    }

    // Should return {key, value, hash}
    ERL_NIF_TERM key_term = argv[1];
    ERL_NIF_TERM value_term = make_binary(env, pair->value.data(), 32);
    ERL_NIF_TERM hash_term = make_binary(env, pair->key_hash.data(), 32);
    ERL_NIF_TERM tuple = enif_make_tuple3(env, key_term, value_term, hash_term);
    return tuple;
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
    enif_release_binary(&key_binary);
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
    mt->shared_state->tree.each([&](pair_t &pair) {
        ERL_NIF_TERM key_term = make_binary(env, pair.key.data(), pair.key.size());
        ERL_NIF_TERM value_term = make_binary(env, pair.value.data(), 32);
        ERL_NIF_TERM tuple = enif_make_tuple2(env, key_term, value_term);
        list = enif_make_list_cell(env, tuple, list);
    });
    return list;
}

static ERL_NIF_TERM
merkletree_lock(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[])
{
    merkletree *mt;

    if (argc != 1) return enif_make_badarg(env);
    if (!enif_get_resource(env, argv[0], merkletree_type, (void **) &mt)) return enif_make_badarg(env);
    Lock lock(mt);
    mt->locked = true;
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

    Lock lock1(mt1);
    if (&mt1->shared_state->tree == &mt2->shared_state->tree) {
        return enif_make_list(env, 0);
    }

    Lock lock2(mt2);

    Tree output;
    mt1->shared_state->tree.difference(mt2->shared_state->tree, output);
    mt2->shared_state->tree.difference(mt1->shared_state->tree, output);

    ERL_NIF_TERM list = enif_make_list(env, 0);
    output.each([&](pair_t &pair) {
        ERL_NIF_TERM key_term = make_binary(env, pair.key.data(), pair.key.size());

        auto pair1 = mt1->shared_state->tree.get_item(pair);
        auto pair2 = mt2->shared_state->tree.get_item(pair);

        ERL_NIF_TERM value1_term = pair1 == nullptr ? make_atom(env, "nil") : make_binary(env, pair1->value.data(), 32);
        ERL_NIF_TERM value2_term = pair2 == nullptr ? make_atom(env, "nil") : make_binary(env, pair2->value.data(), 32);
        ERL_NIF_TERM tuple = enif_make_tuple2(env, value1_term, value2_term);
        tuple = enif_make_tuple2(env, key_term, tuple);
        list = enif_make_list_cell(env, tuple, list);
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

    while (enif_map_iterator_get_pair(env, &iter, &key, &value)) {
        ErlNifBinary key_binary, value_binary;
        if (!enif_inspect_binary(env, key, &key_binary)) return enif_make_badarg(env);
        if (!enif_inspect_binary(env, value, &value_binary)) return enif_make_badarg(env);
        if (value_binary.size != 32) return enif_make_badarg(env);
        bin_t key;
        key.insert(key.end(), key_binary.data, key_binary.data + key_binary.size);
        uint256_t value = (char*)value_binary.data;
        mt->shared_state->tree.insert_item(key, value);
        enif_map_iterator_next(env, &iter);
    }
    enif_map_iterator_destroy(env, &iter);
    return argv[0];
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

static void
destruct_merkletree_type(ErlNifEnv* /*env*/, void *arg)
{
    merkletree *mt = (merkletree *) arg;
    resources--;
    Lock lock(mt);
    if (mt->shared_state->has_clone == 0) {  
        lock.unlock();
        delete(mt->shared_state);
    } else {
        mt->shared_state->has_clone -= 1;
    }
    mt->shared_state = NULL;
}

static int
on_load(ErlNifEnv* env, void** /*priv*/, ERL_NIF_TERM /*info*/)
{
    ErlNifResourceType *rt;

    rt = enif_open_resource_type(env, "merkletree_nif", "merkletree_type",
            destruct_merkletree_type, ERL_NIF_RT_CREATE, NULL);
    if(!rt) return -1;
    merkletree_type = rt;
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
    {"get_proofs_raw", 2, merkletree_get_proofs, 0},
    {"difference_raw", 2, merkletree_difference, 0},
    {"lock", 1, merkletree_lock, 0},
    {"to_list", 1, merkletree_to_list, 0},
    {"import_map", 2, merkletree_import_map, 0},
    {"root_hash", 1, merkletree_root_hash, 0},
    {"hash", 1, merkletree_hash, 0},
    {"root_hashes_raw", 1, merkletree_root_hashes, 0},
    {"bucket_count", 1, merkletree_bucket_count, 0},
    {"size", 1, merkletree_size, 0},
    {"clone", 1, merkletree_clone, 0},
};

// ERL_NIF_INIT(merkletree_nif, nif_funcs, on_load, on_reload, on_upgrade, NULL);
ERL_NIF_INIT(Elixir.CMerkleTree, nif_funcs, on_load, on_reload, on_upgrade, NULL)

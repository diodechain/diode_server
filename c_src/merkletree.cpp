#include "merkletree.hpp"
#include <iostream>
#include <chrono>

extern "C" {
#include "sha.h"
}

void to_erl(bin_t &binary, uint256_t &value);
void to_erl(bin_t &binary, bin_t &value);
void to_erl(bin_t &binary, uint8_t *begin, uint8_t *end);

uint256_t hash(bin_t &input) {
    uint256_t output;
    sha(&input[0], input.size(), output.data());
    return output;
}

uint256_t hash(uint256_t &input) {
    uint256_t output;
    sha(input.data(), 32, output.data());
    return output;
}

pair_list_t *clone_pair_list(const pair_list_t *src, Tree &tree) {
    if (!src) {
        return nullptr;
    }
    auto *d = new pair_list_t(tree);
    for (pair_t *p : *const_cast<pair_list_t *>(src)) {
        d->push_back(*p);
    }
    return d;
}

struct Leaf {
    int num;
    bits_t *prefix;
    pair_list_t *bucket;

    Leaf(Tree &tree) : num(0), prefix(nullptr), bucket(new pair_list_t(tree)) {}

    ~Leaf() {
        delete bucket;
    }

    void to_erl_ext(bin_t &binary) {
        binary.reserve(bucket->size() * 60 + 100);
        binary.push_back(131);
        binary.push_back(108);
        binary.push_back(0);
        binary.push_back(0);
        binary.push_back(0);
        binary.push_back(bucket->size() + 2);

        int overflow = prefix->size() % 8;
        int prefix_size = prefix->size() / 8;
        if (overflow > 0) {
            prefix_size += 1;
            binary.push_back(77);
            binary.push_back(0);
            binary.push_back(0);
            binary.push_back(0);
            binary.push_back(prefix_size);
            binary.push_back(overflow);
            binary.insert(binary.end(), prefix->begin(), prefix->end());
        } else {
            to_erl(binary, prefix->begin(), prefix->end());
        }

        binary.push_back(97);
        binary.push_back(num);

        for (pair_t *pair : *bucket) {
            binary.push_back(104);
            binary.push_back(2);
            to_erl(binary, pair->key);
            to_erl(binary, pair->value);
        }

        binary.push_back(106);
    }
};

void to_erl(bin_t &binary, uint256_t &value) {
    to_erl(binary, value.data(), value.data() + 32);
}

void to_erl(bin_t &binary, bin_t &value) {
    to_erl(binary, value.data(), value.data() + value.size());
}

void to_erl(bin_t &binary, uint8_t *begin, uint8_t *end) {
    binary.push_back(109);
    binary.push_back(0);
    binary.push_back(0);
    binary.push_back(0);
    binary.push_back(end - begin);
    binary.insert(binary.end(), begin, end);
}

void to_erl_ext(bin_t &binary, uint256_t &left, uint256_t &right) {
    binary.reserve(100);
    binary.push_back(131);
    binary.push_back(108);
    binary.push_back(0);
    binary.push_back(0);
    binary.push_back(0);
    binary.push_back(2);
    to_erl(binary, left);
    to_erl(binary, right);
    binary.push_back(106);
}

void to_erl_ext(bin_t &binary, uint256_t *values, int n) {
    binary.reserve(10 + n * 40);
    binary.push_back(131);
    binary.push_back(108);
    binary.push_back(0);
    binary.push_back(0);
    binary.push_back(0);
    binary.push_back(n);
    for (int i = 0; i < n; i++) {
        to_erl(binary, values[i]);
    }
    binary.push_back(106);
}

uint256_t signature(Leaf &leaf, bin_t &binary_buffer) {
    binary_buffer.clear();
    leaf.to_erl_ext(binary_buffer);
    return hash(binary_buffer);
}

uint256_t signature(uint256_t &left, uint256_t &right, bin_t &binary_buffer) {
    binary_buffer.clear();
    to_erl_ext(binary_buffer, left, right);
    return hash(binary_buffer);
}

void map_delete(pair_list_t &map, bin_t &key) {
    for (unsigned i = 0; i < map.size(); i++) {
        if (map[i].key == key) {
            map.erase(i);
            return;
        }
    }
}

bool map_contains(pair_list_t &map, bin_t &key) {
    for (pair_t *pair : map) {
        if (pair->key == key) {
            return true;
        }
    }
    return false;
}

pair_t* map_get(pair_list_t &map, bin_t &key) {
    for (pair_t *pair : map) {
        if (pair->key == key) {
            return pair;
        }
    }
    return nullptr;
}

void map_put(pair_list_t &map, pair_t &new_pair) {
    for (unsigned i = 0; i < map.size(); i++) {
        if (map[i].key == new_pair.key) {
            map[i].value = new_pair.value;
            return;
        } else if (map[i].key > new_pair.key) {
            map.insert(i, new_pair);
            return;
        }
    }
    map.push_back(new_pair);
}

bool decide(pair_t &pair, uint8_t prefix_len) {
    return pair.key_hash.bit(prefix_len) == LEFT;
}

Item::Item(Tree &tree)
    : m_tree(&tree),
      is_leaf(true),
      dirty(true),
      hash_values(nullptr),
      hash_count(0),
      prefix(),
      leaf_bucket(new pair_list_t(tree)),
      node_left(nullptr),
      node_right(nullptr) { }

Item::~Item() {
    delete[] hash_values;
    hash_values = nullptr;
    if (leaf_bucket) {
        delete leaf_bucket;
        leaf_bucket = nullptr;
    }
}

uint256_t *Item::ensure_hashes() {
    if (!hash_values) {
        hash_values = new uint256_t[LEAF_SIZE]();
    }
    return hash_values;
}

std::shared_ptr<Item> Item::fork_for_write(std::shared_ptr<Item> n, Tree &tree) {
    if (!n) {
        return n;
    }
    if (n.use_count() <= 1) {
        return n;
    }
    auto c = std::shared_ptr<Item>(new Item(tree));
    delete c->leaf_bucket;
    c->leaf_bucket = nullptr;
    c->is_leaf = n->is_leaf;
    c->dirty = true;
    c->hash_count = n->hash_count;
    c->prefix = n->prefix;
    if (n->hash_values) {
        c->hash_values = new uint256_t[LEAF_SIZE];
        std::memcpy(c->hash_values, n->hash_values, LEAF_SIZE * sizeof(uint256_t));
    }
    if (n->leaf_bucket) {
        c->leaf_bucket = clone_pair_list(n->leaf_bucket, tree);
    }
    c->node_left = n->node_left;
    c->node_right = n->node_right;
    return c;
}

void Item::each(std::function<void(pair_t &)> func) {
    if (this->is_leaf) {
        for (pair_t *pair : *leaf_bucket) {
            func(*pair);
        }
    } else {
        node_left->each(func);
        node_right->each(func);
    }
}

size_t Item::leaf_count() const {
    if (this->is_leaf) {
        return 1;
    }
    return node_left->leaf_count() + node_right->leaf_count();
}

Tree::Tree() : m_pair_allocator(*this), root(std::make_shared<Item>(*this)) { }

Tree::Tree(const Tree &other) : m_pair_allocator(*this), root(other.root) { }

std::shared_ptr<Item> Tree::make_item() {
    return std::make_shared<Item>(*this);
}

std::shared_ptr<Item> Tree::insert_path(std::shared_ptr<Item> node, pair_t &pair) {
    node = Item::fork_for_write(node, *this);
    if (node->is_leaf) {
        if (pair.value.is_null()) {
            map_delete(*node->leaf_bucket, pair.key);
        } else {
            map_put(*node->leaf_bucket, pair);
            split_node(node);
        }
        return node;
    }
    if (decide(pair, node->prefix.size())) {
        node->node_left = insert_path(node->node_left, pair);
        node->dirty = true;
        return node;
    }
    node->node_right = insert_path(node->node_right, pair);
    node->dirty = true;
    return node;
}

void Tree::split_node(const std::shared_ptr<Item> &tree) {
    Item &t = *tree;
    if (t.leaf_bucket->size() <= LEAF_SIZE) {
        return;
    }

    t.node_left = make_item();
    t.node_left->prefix = t.prefix;
    t.node_left->prefix.push_back(LEFT);

    t.node_right = make_item();
    t.node_right->prefix = t.prefix;
    t.node_right->prefix.push_back(RIGHT);

    for (pair_t *pair : *t.leaf_bucket) {
        if (decide(*pair, t.prefix.size())) {
            t.node_left->leaf_bucket->push_back_no_delete(pair);
        } else {
            t.node_right->leaf_bucket->push_back_no_delete(pair);
        }
    }

    split_node(t.node_left);
    split_node(t.node_right);

    t.leaf_bucket->clear_no_delete();
    delete t.leaf_bucket;
    t.leaf_bucket = nullptr;
    t.is_leaf = false;
    t.dirty = true;
}

void Tree::insert_item(bin_t &key, uint256_t &value) {
    pair_t pair(key, value);
    insert_item(pair);
}

void Tree::insert_item(pair_t &pair) {
    root = insert_path(root, pair);
}

void Tree::insert_items(pair_list_t &items) {
    for (pair_t *pair : items) {
        insert_item(*pair);
    }
}

int hash_to_leafindex(pair_t &pair) {
    return pair.key_hash.last_byte() % LEAF_SIZE;
}

void bucket_to_leaf(Item &item, Leaf& leaf, int i) {
    leaf.prefix = &item.prefix;
    leaf.num = i;
    leaf.bucket->clear();

    for (pair_t *pair : *item.leaf_bucket) {
        int index = hash_to_leafindex(*pair);
        if (index == i) {
            leaf.bucket->push_back(*pair);
        }
    }
}

void Tree::bucket_to_leafes(Item &item, bin_t &binary_buffer) {
    Leaf leaf(*this);
    leaf.prefix = &item.prefix;
    uint256_t *hv = item.ensure_hashes();

    for (int i = 0; i < LEAF_SIZE; i++) {
        bucket_to_leaf(item, leaf, i);
        hv[i] = signature(leaf, binary_buffer);
    }
}

void Tree::update_merkle_hash_count(const std::shared_ptr<Item> &item, bin_t &binary_buffer) {
    if (!item || !item->dirty) {
        return;
    }
    Item &it = *item;
    if (it.is_leaf) {
        if (it.leaf_bucket->size() > LEAF_SIZE) {
            split_node(item);
            update_merkle_hash_count(item, binary_buffer);
        } else {
            bucket_to_leafes(it, binary_buffer);
            it.hash_count = it.leaf_bucket->size();
        }
    } else {
        update_merkle_hash_count(it.node_left, binary_buffer);
        update_merkle_hash_count(it.node_right, binary_buffer);
        it.hash_count = it.node_left->hash_count + it.node_right->hash_count;
        uint256_t *hv = it.ensure_hashes();
        if (it.hash_count <= LEAF_SIZE) {
            if (!it.leaf_bucket) {
                it.leaf_bucket = new pair_list_t(*it.m_tree);
            }
            it.each([&it](pair_t &pair) {
                map_put(*it.leaf_bucket, pair);
            });
            it.node_left.reset();
            it.node_right.reset();
            it.is_leaf = true;
            bucket_to_leafes(it, binary_buffer);
        } else {
            for (int i = 0; i < LEAF_SIZE; i++) {
                uint256_t *lh = it.node_left->ensure_hashes();
                uint256_t *rh = it.node_right->ensure_hashes();
                hv[i] = signature(lh[i], rh[i], binary_buffer);
            }
        }
    }
    it.dirty = false;
}

uint256_t Tree::root_hash() {
    bin_t binary_buffer;
    if (root->is_leaf) {
        update_merkle_hash_count(root, binary_buffer);
    } else {
        update_merkle_hash_count(root, binary_buffer);
    }

    binary_buffer.clear();
    uint256_t *hv = root->ensure_hashes();
    to_erl_ext(binary_buffer, hv, LEAF_SIZE);
    return hash(binary_buffer);
}

uint256_t* Tree::root_hashes() {
    bin_t binary_buffer;
    update_merkle_hash_count(root, binary_buffer);
    return root->ensure_hashes();
}

size_t Tree::size() {
    size_t count = 0;
    root->each([&count](pair_t &) {
        count++;
    });
    return count;
}

size_t Tree::leaf_count() {
    bin_t binary_buffer;
    update_merkle_hash_count(root, binary_buffer);
    return root->leaf_count();
}

static size_t count_nodes(const std::shared_ptr<Item> &item) {
    if (!item) {
        return 0;
    }
    if (item->is_leaf) {
        return 1;
    }
    return 1 + count_nodes(item->node_left) + count_nodes(item->node_right);
}

size_t Tree::node_count() const {
    return count_nodes(root);
}

proof_t make_hash_proof(uint256_t &hash) {
    proof_t ret;
    ret.type = 1;
    ret.hash = hash;
    return ret;
}

proof_t do_get_proofs(Tree &tree, Item &item, pair_t &pair) {
    proof_t ret;
    if (item.is_leaf) {
        Leaf leaf(tree);
        bucket_to_leaf(item, leaf, hash_to_leafindex(pair));

        ret.type = 2;
        leaf.to_erl_ext(ret.term);
        return ret;
    }

    ret.type = 0;
    bin_t buf;
    tree.update_merkle_hash_count(item.node_left, buf);
    tree.update_merkle_hash_count(item.node_right, buf);
    uint256_t *rl = item.node_right->ensure_hashes();
    uint256_t *ll = item.node_left->ensure_hashes();
    int idx = hash_to_leafindex(pair);
    if (decide(pair, item.prefix.size())) {
        ret.left = std::make_unique<proof_t>(do_get_proofs(tree, *item.node_left, pair));
        ret.right = std::make_unique<proof_t>(make_hash_proof(rl[idx]));
    } else {
        ret.left = std::make_unique<proof_t>(make_hash_proof(ll[idx]));
        ret.right = std::make_unique<proof_t>(do_get_proofs(tree, *item.node_right, pair));
    }

    return ret;
}

proof_t Tree::get_proofs(bin_t& key) {
    pair_t pair(key);
    bin_t binary_buffer;
    update_merkle_hash_count(root, binary_buffer);
    return do_get_proofs(*this, *root, pair);
}

pair_t* Tree::get_item(bin_t &&key) {
    pair_t pair(key);
    return get_item(pair);
}

static Item &get_bucket(std::shared_ptr<Item> item, pair_t &pair) {
    if (item->is_leaf) {
        return *item;
    }
    if (decide(pair, item->prefix.size())) {
        return get_bucket(item->node_left, pair);
    }
    return get_bucket(item->node_right, pair);
}

pair_t* Tree::get_item(pair_t &pair) {
    Item &leaf = get_bucket(root, pair);
    return map_get(*leaf.leaf_bucket, pair.key);
}

void Tree::difference(Tree &other, Tree &into) {
    each([&other, &into](pair_t &pair) {
        pair_t* other_pair = other.get_item(pair);
        if (other_pair == nullptr || other_pair->value != pair.value) {
            into.insert_item(pair);
        }
    });
}

pair_list_t::pair_list_t(Tree &tree) : m_allocator(tree.m_pair_allocator), m_size(0) {}

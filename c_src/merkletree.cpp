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

    // std::cout << "input/output: ";
    // for (uint8_t &byte : input) {
    //     std::cout << std::hex << std::setfill('0') << std::setw(2) << int(byte);
    // }
    // std::cout << " ";
    // for (uint8_t &byte : output) {
    //     std::cout << std::hex << std::setfill('0') << std::setw(2) << int(byte);
    // }
    // std::cout << std::endl;

    return output;
}

uint256_t hash(uint256_t &input) {
    uint256_t output;
    sha(input.data(), 32, output.data());

    // std::cout << "input/output: ";
    // for (uint8_t &byte : input) {
    //     std::cout << std::hex << std::setfill('0') << std::setw(2) << int(byte);
    // }
    // std::cout << " ";
    // for (uint8_t &byte : output) {
    //     std::cout << std::hex << std::setfill('0') << std::setw(2) << int(byte);
    // }
    // std::cout << std::endl;

    return output;
}

struct Leaf {
    int num;
    bits_t *prefix;
    pair_list_t bucket;

    Leaf() : num(0), prefix(nullptr), bucket(pair_list_t()) {}

    void to_erl_ext(bin_t &binary) {
        // [prefix, num, {key, value}]
        binary.reserve(bucket.size() * 60 + 100);
        binary.push_back(131);
        binary.push_back(108);
        binary.push_back(0);
        binary.push_back(0);
        binary.push_back(0);
        binary.push_back(bucket.size() + 2);

        // prefix encoded as BIT_BINARY_EXT
        // https://www.erlang.org/doc/apps/erts/erl_ext_dist.html#bit_binary_ext
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

        // num encoded as SMALL_INTEGER_EXT
        // https://www.erlang.org/doc/apps/erts/erl_ext_dist.html#small_integer_ext
        binary.push_back(97);
        binary.push_back(num);
        
        for (pair_t &pair : bucket) {
            // bucket encoded as SMALL_TUPLE_EXT with two elemens
            binary.push_back(104);
            binary.push_back(2);

            // key encoded as BINARY_EXT
            to_erl(binary, pair.key);
            // value encoded as BINARY_EXT
            to_erl(binary, pair.value);
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
    // [left, right]
    binary.reserve(100);
    binary.push_back(131);
    binary.push_back(108);
    binary.push_back(0);
    binary.push_back(0);
    binary.push_back(0);
    binary.push_back(2);

    // left encoded as BINARY_EXT
    to_erl(binary, left);
    to_erl(binary, right);

    binary.push_back(106);
}

void to_erl_ext(bin_t &binary, uint256_t (&values)[LEAF_SIZE]) {
    binary.reserve(10 + LEAF_SIZE * 40);
    binary.push_back(131);
    binary.push_back(108);
    binary.push_back(0);
    binary.push_back(0);
    binary.push_back(0);
    binary.push_back(LEAF_SIZE);

    // left encoded as BINARY_EXT
    for (uint256_t &value : values) {
        to_erl(binary, value);
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
    for (pair_t &pair : map) {
        if (pair.key == key) {
            return true;
        }
    }
    return false;
}

pair_t map_get(pair_list_t &map, bin_t &key) {
    for (pair_t &pair : map) {
        if (pair.key == key) {
            return pair;
        }
    }
    return pair_t();
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

Item &update_bucket(Item &tree, pair_t &pair) {
    tree.dirty = true;
    if (tree.is_leaf) return tree;

    if (decide(pair, tree.prefix.size())) {
        return update_bucket(*tree.node_left, pair);
    } else {
        return update_bucket(*tree.node_right, pair);
    }
}

Item &get_bucket(Item &item, pair_t &pair) {
    if (item.is_leaf) return item;

    if (decide(pair, item.prefix.size())) {
        return get_bucket(*item.node_left, pair);
    } else {
        return get_bucket(*item.node_right, pair);
    }
}

void Tree::insert_item(bin_t &key, uint256_t &value) {
    pair_t pair = {key, value, hash(key)};
    insert_item(pair);
}

void Tree::insert_item(pair_t &pair) {
    Item &leaf = update_bucket(this->root, pair);
    if (pair.value.is_null()) {
        map_delete(leaf.leaf_bucket, pair.key);
    } else {
        map_put(leaf.leaf_bucket, pair);
        split_node(leaf);
    }
}

void Tree::insert_items(pair_list_t &items) {
    for (pair_t &pair : items) {
        insert_item(pair);
    }
}

int hash_to_leafindex(pair_t &pair) { 
    return pair.key_hash.last_byte() % LEAF_SIZE;
}

void bucket_to_leaf(Item &item, Leaf& leaf, int i) {
    leaf.prefix = &item.prefix;
    leaf.num = i;
    leaf.bucket.clear();

    for (pair_t &pair : item.leaf_bucket) {
        int index = hash_to_leafindex(pair);
        if (index == i) {
            leaf.bucket.push_back(pair);
        }
    }
}

void bucket_to_leafes(Item &item, bin_t &binary_buffer) {
    Leaf leaf;
    leaf.prefix = &item.prefix;

    for (int i = 0; i < LEAF_SIZE; i++) {
        bucket_to_leaf(item, leaf, i);
        item.hash_values[i] = signature(leaf, binary_buffer);
    }
}

void Tree::split_node(Item &tree) {
    if (tree.leaf_bucket.size() <= LEAF_SIZE) {
        return;
    }

    tree.node_left = new_item();
    tree.node_left->prefix = tree.prefix;
    tree.node_left->prefix.push_back(LEFT);

    tree.node_right = new_item();
    tree.node_right->prefix = tree.prefix;
    tree.node_right->prefix.push_back(RIGHT);

    for (pair_t &pair : tree.leaf_bucket) {
        if (decide(pair, tree.prefix.size())) {
            tree.node_left->leaf_bucket.push_back(pair);
        } else {
            tree.node_right->leaf_bucket.push_back(pair);
        }
    }

    split_node(*tree.node_left);
    split_node(*tree.node_right);

    tree.leaf_bucket.clear();
    tree.is_leaf = false;
    tree.dirty = true;
}

void Tree::update_merkle_hash_count(Item &item, bin_t &binary_buffer) {
    if (!item.dirty) {
        return;
    }
    if (item.is_leaf) {
        if (item.leaf_bucket.size() > LEAF_SIZE) {
            split_node(item);
            update_merkle_hash_count(item, binary_buffer);
        } else {
            bucket_to_leafes(item, binary_buffer);
            item.hash_count = item.leaf_bucket.size();
        }
    } else {
        update_merkle_hash_count(*item.node_left, binary_buffer);
        update_merkle_hash_count(*item.node_right, binary_buffer);
        item.hash_count = item.node_left->hash_count + item.node_right->hash_count;
        if (item.hash_count <= LEAF_SIZE) {
            item.each([&item](pair_t &pair) {
                // When removing we need to ensure the pair order is correct
                map_put(item.leaf_bucket, pair);
            });
            // TODO: delete node_left and node_right
            item.node_left = 0;
            item.node_right = 0;
            item.is_leaf = true;
            bucket_to_leafes(item, binary_buffer);
        } else {
            for (int i = 0; i < LEAF_SIZE; i++) {
                item.hash_values[i] = signature(item.node_left->hash_values[i], item.node_right->hash_values[i], binary_buffer);
            }
        }
    }
    item.dirty = false;
}

uint256_t Tree::root_hash() {
    bin_t binary_buffer;
    if (root.is_leaf) {
        update_merkle_hash_count(root, binary_buffer);
    } else { 
        #pragma omp parallel sections
        {
            #pragma omp section
            {
                update_merkle_hash_count(*root.node_left, binary_buffer);
            }
            #pragma omp section
            {
                bin_t binary_buffer_right;
                update_merkle_hash_count(*root.node_right, binary_buffer_right);
            }
        }
        update_merkle_hash_count(root, binary_buffer);
    }

    binary_buffer.clear();
    to_erl_ext(binary_buffer, root.hash_values);
    return hash(binary_buffer);
}

uint256_t* Tree::root_hashes() {
    bin_t binary_buffer;
    update_merkle_hash_count(root, binary_buffer);
    return root.hash_values;
}

size_t Tree::size() {
    size_t count = 0;
    root.each([&count](pair_t &) {
        count++;
    });
    return count;
}

size_t Tree::leaf_count() {
    bin_t binary_buffer;
    update_merkle_hash_count(root, binary_buffer);
    return root.leaf_count();
}

proof_t make_hash_proof(uint256_t &hash) {
    proof_t ret;
    ret.type = 1;
    ret.hash = hash;
    return ret;
}

proof_t do_get_proofs(Item &item, pair_t &pair) {
    proof_t ret;
    if (item.is_leaf) {
        Leaf leaf; 
        bucket_to_leaf(item, leaf, hash_to_leafindex(pair));

        ret.type = 2;
        leaf.to_erl_ext(ret.term);
        return ret;
    }

    ret.type = 0;
    if (decide(pair, item.prefix.size())) {
        ret.left = std::make_unique<proof_t>(do_get_proofs(*item.node_left, pair));
        ret.right = std::make_unique<proof_t>(make_hash_proof(item.node_right->hash_values[hash_to_leafindex(pair)]));
    } else {
        ret.left = std::make_unique<proof_t>(make_hash_proof(item.node_left->hash_values[hash_to_leafindex(pair)]));
        ret.right = std::make_unique<proof_t>(do_get_proofs(*item.node_right, pair));
    }

    return ret;
}

proof_t Tree::get_proofs(bin_t& key) {
    pair_t pair = {key, uint256_t(), hash(key)};
    bin_t binary_buffer;
    update_merkle_hash_count(root, binary_buffer);
    return do_get_proofs(root, pair);
}

pair_t Tree::get_item(bin_t &key) {
    pair_t pair = {key, uint256_t(), hash(key)};
    return get_item(pair);
}

pair_t Tree::get_item(pair_t &pair) {
    return map_get(get_bucket(root, pair).leaf_bucket, pair.key);
}

void Tree::difference(Tree &other, Tree &into) {
    each([&other, &into](pair_t &pair) {
        pair_t other_pair = other.get_item(pair);
        if (other_pair.value != pair.value) {
            into.insert_item(pair);
        }
    });
}
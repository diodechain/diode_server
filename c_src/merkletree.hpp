#include <vector>
#include <cstdint>
#include <memory>
#include <functional>
#include <cstring>
#include <sstream>
#include <iomanip>
#include <list>

#include "item_pool.hpp"
#include "preallocator.hpp"

const int LEAF_SIZE = 16;
const int LEFT = 0;
const int RIGHT = 1;

typedef std::vector<uint8_t> bin_t;

class Tree;

struct bits_t {
    uint8_t m_value[16];
    size_t m_value_size;
    size_t m_size;

public:
    bits_t() : m_value_size(0), m_size(0) {}

    uint8_t byte(size_t index) {
        return m_value[index];
    }

    uint8_t *begin() {
        return m_value;
    }

    uint8_t *end() {
        return m_value + m_value_size;
    }

    bool bit(int index) {
        int elem = index / (sizeof(m_value[0]) * 8);
        int bit = 7 - (index % (sizeof(m_value[0]) * 8));
        return (m_value[elem] & (1 << bit)) != 0;
    }

    size_t size() {
        return m_size;
    }

    void push_back(bool bit) {
        if (m_size + 1 > m_value_size * sizeof(m_value[0]) * 8) {
            m_value[m_value_size] = 0;
            m_value_size++;
        }
        if (bit) {
            auto shift = 7 - (m_size % (sizeof(m_value[0]) * 8));
            m_value[m_value_size - 1] |= 1 << shift;
        }

        m_size++;
    }
};

struct uint256_t {
    uint8_t value[32];

public:
    uint256_t() : value{0} { }
    uint256_t(const char *data) {
        std::memcpy(value, data, sizeof(value));
    }

    uint8_t *data() {
        return (uint8_t *)value;
    }

    uint8_t *begin() {
        return data();
    }

    uint8_t *end() {
        return data() + sizeof(value);
    }

    bool bit(int index) {
        int elem = index / (sizeof(value[0]) * 8);
        int bit = 7 - (index % (sizeof(value[0]) * 8));
        return (value[elem] & (1 << bit)) != 0;
    }

    bool is_null() {
        for (unsigned i = 0; i < sizeof(value)/sizeof(value[0]); i++) {
            if (value[i] != 0) {
                return false;
            }
        }
        return true;
    }

    uint8_t last_byte() {
        return value[sizeof(value)/sizeof(value[0]) - 1];
    }

    int compare(const uint256_t &other) const {
        return memcmp(value, other.value, sizeof(value));
    }

    bool operator==(const uint256_t &other) const {
        return compare(other) == 0;
    }

    bool operator!=(const uint256_t &other) const {
        return compare(other) != 0;
    }

    std::string hex() {
        std::stringstream ss;
        ss << "0x";
        ss << std::hex << std::setfill('0');
        for (unsigned i = 0; i < sizeof(value)/sizeof(value[0]); i++) {
            ss << std::setw(2*sizeof(value[0])) << int(value[i]);
        }
        return ss.str();
    }
};

namespace std {
    template<>
    struct hash<uint256_t> {
        std::size_t operator()(const uint256_t& k) const {
            std::size_t res = 0;
            for (size_t i = 0; i < sizeof(k.value); ++i) {
                res ^= std::hash<unsigned char>()(k.value[i]) + 0x9e3779b9 + (res << 6) + (res >> 2);
            }
            return res;
        }
    };
}

uint256_t hash(bin_t &input);

class pair_t {
public:
    pair_t() = default;
    pair_t(bin_t &key, uint256_t &value, uint256_t &key_hash) : key(key), value(value), key_hash(key_hash) { }
    pair_t(bin_t &_key, uint256_t &value) : key(_key), value(value), key_hash(hash(key)) { }
    pair_t(bin_t &_key) : key(_key), value(), key_hash(hash(key)) { }
    pair_t(bin_t &&_key) : key(_key), value(), key_hash(hash(key)) { }
    pair_t(Tree& /*tree*/) : key(), value(), key_hash() { }
    pair_t(const pair_t &other) = default;
    pair_t& operator=(const pair_t &other) = default;
    bin_t key;
    uint256_t value;
    uint256_t key_hash;
};

struct pair_list_t {
    PreAllocator<pair_t> &m_allocator;
    pair_t* m_pairs[LEAF_SIZE + 1];
    size_t m_size;

public:
    pair_list_t(Tree &tree);
    ~pair_list_t() { clear(); }

    void push_back_no_delete(pair_t *pair) {
        m_pairs[m_size++] = pair;
    }

    void push_back(pair_t &pair) {
        auto new_pair = m_allocator.new_item();
        *new_pair = pair;
        m_pairs[m_size++] = new_pair;
    }

    pair_t **begin() {
        return m_pairs;
    }

    pair_t **end() {
        return m_pairs + m_size;
    }

    pair_t &operator[](size_t index) {
        return *m_pairs[index];
    }

    size_t size() {
        return m_size;
    }

    void erase(size_t index) {
        m_allocator.destroy_item(m_pairs[index]);
        for (size_t i = index; i < m_size - 1; i++) {
            m_pairs[i] = m_pairs[i + 1];
        }
        m_size--;
    }

    void insert(size_t index, pair_t &pair) {
        for (size_t i = m_size; i > index; i--) {
            m_pairs[i] = m_pairs[i - 1];
        }
        m_pairs[index] = m_allocator.new_item();
        *m_pairs[index] = pair;
        m_size++;
    }

    void clear() {
        for (size_t i = 0; i < m_size; i++) {
            m_allocator.destroy_item(m_pairs[i]);
        }

        m_size = 0;
    }

    void clear_no_delete() {
        m_size = 0;
    }
};

pair_list_t *clone_pair_list(const pair_list_t *src, Tree &tree);

// Key-byte interning and content-addressed subtree sharing would require pair_t / node
// representation changes; not implemented here.
// Trie edges use ItemId (32-bit) into ItemPool with refcounted COW; lazy hash_values; internal
// nodes use leaf_bucket nullptr.

struct proof_t {
    proof_t() = default;
    proof_t(proof_t&&) = default;
    proof_t &operator=(proof_t&&) = default;

    uint8_t type;

    std::unique_ptr<proof_t> left;
    std::unique_ptr<proof_t> right;

    uint256_t hash;

    bin_t term;
};

struct Item {
    Tree *m_tree;
    bool is_leaf;
    bool dirty;
    uint256_t *hash_values;
    uint64_t hash_count;
    bits_t prefix;
    pair_list_t *leaf_bucket;
    ItemId left_id;
    ItemId right_id;

    explicit Item(Tree &tree);
    ~Item();

    Item(const Item &other) = delete;
    Item& operator=(const Item &other) = delete;

    void each(Tree &tree, std::function<void(pair_t &)> func);
    size_t leaf_count(const Tree &tree) const;

    uint256_t *ensure_hashes();
    const uint256_t *hashes_ro() const { return hash_values; }
};

class Tree {
public:
    /** Shared across Tree copies (NIF SharedState fork): pair_t live here while ItemPool nodes may be shared. */
    std::shared_ptr<PreAllocator<pair_t>> m_pair_allocator;
    std::shared_ptr<ItemPool> pool;
    ItemId root_id;

    void split_node(ItemId tree_id);
    void update_merkle_hash_count(ItemId item_id, bin_t &binary_buffer);
    void bucket_to_leafes(Item &item, bin_t &binary_buffer);

    Item *node(ItemId id) { return pool->get(id); }
    const Item *node(ItemId id) const { return pool->get(id); }

    ItemId fork_for_write(ItemId id);

    Tree();
    Tree(const Tree &other);
    Tree& operator=(const Tree &other) = delete;
    ~Tree();

    void insert_item(pair_t &pair);
    void insert_item(bin_t &key, uint256_t &value);
    void insert_items(pair_list_t &items);
    void delete_item(bin_t &key) {
        uint256_t null_value = {};
        insert_item(key, null_value);
    }
    pair_t* get_item(bin_t &&key);
    pair_t* get_item(pair_t &key);
    proof_t get_proofs(bin_t &key);
    uint256_t root_hash();
    uint256_t* root_hashes();
    size_t size();
    size_t leaf_count();
    size_t node_count() const;
    void each(std::function<void(pair_t &)> func) {
        if (root_id != kItemNull) {
            pool->get(root_id)->each(*this, func);
        }
    }
    void difference(Tree &other, Tree &into);

private:
    ItemId insert_path(ItemId node_id, pair_t &pair);
};

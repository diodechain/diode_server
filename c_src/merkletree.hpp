#include <vector>
#include <cstdint>
#include <memory>
#include <functional>
#include <cstring>
#include <sstream>  // Add this line
#include <iomanip>  // Also add this for std::setfill and std::setw
#include <list>

#include "preallocator.hpp"

const int LEAF_SIZE = 16;
const int LEFT = 0;
const int RIGHT = 1;

typedef std::vector<uint8_t> bin_t;

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

uint256_t hash(bin_t &input);

class pair_t {
public:
    pair_t() = default;
    pair_t(bin_t &key, uint256_t &value, uint256_t &key_hash) : key(key), value(value), key_hash(key_hash) { }
    pair_t(bin_t &key, uint256_t &value) : key(key), value(value), key_hash(hash(key)) { }
    pair_t(bin_t &key) : key(key), value(), key_hash(hash(key)) { }
    pair_t(Tree& /*tree*/) : key(), value(), key_hash() { }
    pair_t(const pair_t &other) = default;
    pair_t& operator=(const pair_t &other) = default;
    bin_t key;
    uint256_t value;
    uint256_t key_hash;
};

// typedef std::vector<pair_t> pair_list_t;
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

struct Item {
    Item(Tree &tree) : is_leaf(true), dirty(true), hash_count(0), prefix(), leaf_bucket(tree), node_left(nullptr), node_right(nullptr) { };
    ~Item() = default;
    Item(const Item &other) = delete;
    Item& operator=(const Item &other) = delete;

    void each(std::function<void(pair_t &)> func) {
        if (this->is_leaf) {
            for (pair_t *pair : leaf_bucket) {
                func(*pair);
            }
        } else {
            node_left->each(func);
            node_right->each(func);
        }
    }

    size_t leaf_count() {
        if (this->is_leaf) {
            return 1;
        }
        return node_left->leaf_count() + node_right->leaf_count();
    }

    bool is_leaf;
    bool dirty;
    uint256_t hash_values[LEAF_SIZE];
    uint64_t hash_count;
    bits_t prefix;
    pair_list_t leaf_bucket;
    Item* node_left;
    Item* node_right;
};

struct proof_t {
    proof_t() = default;
    proof_t(proof_t&&) = default;
    proof_t &operator=(proof_t&&) = default;

    uint8_t type;

    // 0:   {left, right}
    std::unique_ptr<proof_t> left;
    std::unique_ptr<proof_t> right;

    // 1:   binary hash
    uint256_t hash;

    // 2:   erlang binary term of: [prefix, position, {key, value}, ...]
    //      this is because `prefix` is a bitstring that is not creatable
    //      using the enif_* api
    bin_t term;
};

class Tree {
public:
    PreAllocator<pair_t> m_pair_allocator;
    PreAllocator<Item> m_allocator;
    Item *root;

    Item* new_item() { return m_allocator.new_item(); }
    void destroy_item(Item* item) { m_allocator.destroy_item(item); }
    void split_node(Item &tree);
    void update_merkle_hash_count(Item &item, bin_t &binary_buffer);
    void bucket_to_leafes(Item &item, bin_t &binary_buffer);

    Tree() : m_pair_allocator(*this), m_allocator(*this), root(new_item()) { };
    Tree(const Tree &other) : m_pair_allocator(*this), m_allocator(*this), root(new_item()) {
        ((Tree &)other).each([&](pair_t &pair) {
            insert_item(pair);
        });
    }
    Tree& operator=(const Tree &other) = delete;
    ~Tree() { root = nullptr; }

    void insert_item(pair_t &pair);
    void insert_item(bin_t &key, uint256_t &value);
    void insert_items(pair_list_t &items);
    void delete_item(bin_t &key) { 
        uint256_t null_value = {};
        insert_item(key, null_value); 
    }
    pair_t get_item(bin_t &key);
    pair_t get_item(pair_t &key);
    proof_t get_proofs(bin_t &key);
    uint256_t root_hash();
    uint256_t* root_hashes();
    size_t size();
    size_t leaf_count();
    void each(std::function<void(pair_t &)> func) {
        root->each(func);
    }
    void difference(Tree &other, Tree &into);
};

#include <vector>
#include <cstdint>
#include <memory>
#include <functional>
#include <cstring>
#include <sstream>  // Add this line
#include <iomanip>  // Also add this for std::setfill and std::setw
#include <list>

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

struct pair_t {
    bin_t key;
    uint256_t value;
    uint256_t key_hash;
};

// typedef std::vector<pair_t> pair_list_t;
struct pair_list_t {
    pair_t m_pairs[LEAF_SIZE + 1];
    size_t m_size;

public:
    // pair_list_t() : m_size(0) {}

    void push_back(pair_t &pair) {
        m_pairs[m_size++] = pair;
    }

    pair_t *begin() {
        return m_pairs;
    }

    pair_t *end() {
        return m_pairs + m_size;
    }

    pair_t &operator[](size_t index) {
        return m_pairs[index];
    }

    size_t size() {
        return m_size;
    }

    void erase(size_t index) {
        for (size_t i = index; i < m_size - 1; i++) {
            m_pairs[i] = m_pairs[i + 1];
        }
        m_size--;
    }

    void insert(size_t index, pair_t &pair) {
        for (size_t i = m_size; i > index; i--) {
            m_pairs[i] = m_pairs[i - 1];
        }
        m_pairs[index] = pair;
        m_size++;
    }

    void clear() {
        m_size = 0;
    }
};

struct Item {
    Item() : is_leaf(true), dirty(true), hash_count(0), prefix(), leaf_bucket(), node_left(nullptr), node_right(nullptr) { };
    ~Item() { };
    Item(const Item &other) = delete;
    Item& operator=(const Item &other) = delete;

    void each(std::function<void(pair_t &)> func) {
        if (this->is_leaf) {
            for (pair_t &pair : leaf_bucket) {
                func(pair);
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
    static const size_t STRIPE_SIZE = 128;
    std::list<uint8_t*> m_stripes;
    size_t m_item_count;
    std::list<Item*> m_backbuffer;
    Item root;

    Item* new_item() {
        if (!m_backbuffer.empty()) {
            Item* item = m_backbuffer.front();
            m_backbuffer.pop_front();
            return new (item) Item();
        }

        if (m_item_count + 1 > m_stripes.size() * STRIPE_SIZE) {
            m_stripes.push_back((uint8_t*)malloc(STRIPE_SIZE * sizeof(Item)));
        }

        Item* item = reinterpret_cast<Item*>(&m_stripes.back()[m_item_count % STRIPE_SIZE * sizeof(Item)]);
        m_item_count++;
        return new (item) Item();
    }

    void destroy_item(Item* item) {
        m_backbuffer.push_back(item);
    }

    void split_node(Item &tree);
    void update_merkle_hash_count(Item &item, bin_t &binary_buffer);

public:
    Tree() : m_stripes(), m_item_count(0), m_backbuffer(), root() { };
    Tree(const Tree &other) : m_stripes(), m_item_count(0), m_backbuffer(), root() {
        ((Tree &)other).root.each([&](pair_t &pair) {
            insert_item(pair);
        });
    }
    Tree& operator=(const Tree &other) = delete;
    ~Tree() {
        for (uint8_t *stripe : m_stripes) {
            free(stripe);
        }
    }
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
        root.each(func);
    }
    void difference(Tree &other, Tree &into);
};

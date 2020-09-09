// EVMC Wrapper
// Copyright 2019 IoT Blockchain Technology Corporation LLC (IBTC)
// Licensed under the GNU General Public License, Version 3.
#include <evmc/evmc.hpp>
#include <unordered_map>
#include <utility>
#include <byteswap.h>

#ifdef DEBUG
static std::string _dlog_hex(const uint8_t *p, size_t i)
{
    static char x[] = "0123456789abcdef";
    static char buff[65] = {};
    size_t j;
    for (j = 0; j < i; j++)
    {
        buff[2 * j] = x[p[j] / 16];
        buff[2 * j + 1] = x[p[j] % 16];
    }
    buff[2 * j] = 0;
    return std::string(buff);
}
#define hex(expr) _dlog_hex(expr, sizeof(expr)).c_str()
class scope_log
{
public:
    char message[128];
    ~scope_log()
    {
        fprintf(stderr, "~%s", message);
    }
};
#define dlog(format, ...)                   \
    fprintf(stderr, format, ##__VA_ARGS__); \
    scope_log log;                          \
    sprintf(log.message, format, ##__VA_ARGS__);
#else
#define dlog(format, ...)
#endif

#define bread(expr) fread(expr.bytes, sizeof(expr.bytes));
static void fread(void *ptr, size_t size)
{
    if (size == 0)
        return;
    if (fread(ptr, size, 1, stdin) != 1)
        exit(1);
}
template <typename T>
T iread()
{
    T tmp;
    fread(&tmp, sizeof(tmp));
    return tmp;
}

static void fwrite(const void *ptr, size_t size) { fwrite(ptr, size, 1, stdout); }

// Read and write port package size
static void nread() { iread<uint32_t>(); }
static void nwrite(uint32_t num)
{
    num = __bswap_32(num);
    fwrite(&num, sizeof(num));
}

namespace std
{
    /// Hash operator template specialization for evmc::address. Needed for unordered containers.
    template <>
    struct hash<pair<evmc::address, evmc::bytes32>>
    {
        /// Hash operator using FNV1a-based folding.
        constexpr size_t operator()(const pair<evmc::address, evmc::bytes32> &s) const noexcept
        {
            using namespace evmc;
            using namespace fnv;
            return hash<evmc::address>()(s.first) ^ hash<evmc::bytes32>()(s.second);
        }
    };

}; // namespace std

template <class Key, class Value, class Hash = std::hash<Key>>
class Map
{
    struct Data
    {
        Data() = default;

        bool used;
        Key key{};
        Value value{};
    };
    std::vector<Data> m_list;
    size_t m_usage;
    Hash m_hasher;

public:
    std::vector<Data> &list()
    {
        return m_list;
    }

    void reserve(size_t size)
    {
        if (capacity() < size) {
            Map<Key, Value, Hash> instance;
            instance.m_list.resize(size);
            if (m_usage > 0)
            {
                for (auto &data : m_list)
                {
                    if (data.used)
                        instance.set(data.key, data.value);
                }
            }
            m_list.swap(instance.m_list);
        }
    }

    size_t size()
    {
        return m_usage;
    }

    size_t capacity()
    {
        return m_list.size();
    }

    Value *get(const Key &key)
    {
        size_t index = m_hasher(key) % capacity();
        while (m_list[index].used == true && m_list[index].key != key)
        {
            index = (index + 1) % capacity();
        }
        if (!m_list[index].used)
        {
            return 0;
        }
        return &m_list[index].value;
    }

    void set(const Key &key, const Value &value)
    {
        *ensure(key) = value;
    }

    Value *ensure(const Key &key)
    {
        if (size() + 1 > (capacity() / 2)) {
            auto target = capacity() * 2 > 32 ? capacity() * 2 : 32;
            reserve(target);
        }
        size_t index = m_hasher(key) % capacity();
        while (m_list[index].used == true && m_list[index].key != key)
        {
            index = (index + 1) % capacity();
        }
        if (!m_list[index].used)
        {
            m_list[index].used = true;
            m_list[index].key = key;
            m_usage++;
        }
        return &m_list[index].value;
    }

    void clear()
    {
        for (auto &data : m_list)
        {
            if (data.used)
            {
                data = Data{};
            }
        }
        m_usage = 0;
    }
};

class Host : public evmc::Host
{
    std::vector<evmc::bytes32> m_buffer{};
    Map<evmc::address, bool> m_complete_accounts{};
    Map<std::pair<evmc::address, evmc::bytes32>, evmc::bytes32> m_storage_cache{};
    Map<std::pair<evmc::address, evmc::bytes32>, evmc::bytes32> m_storage_write_cache{};

public:
    evmc_tx_context tx_context{};

    Host() = default;
    void reset();
    bool complete_account(const evmc::address &addr) noexcept;
    void set_complete_account(const evmc::address &addr) noexcept;
    void set_cache(const evmc::address &addr, const evmc::bytes32 &key, const evmc::bytes32 &value) noexcept;
    bool get_cache(const evmc::address &addr, const evmc::bytes32 &key, evmc::bytes32 &out) noexcept;
    void send_updates() noexcept;
    void read_updates() noexcept;

    bool account_exists(const evmc::address &addr) noexcept final;
    evmc::bytes32 get_storage(const evmc::address &addr, const evmc::bytes32 &key) noexcept final;
    evmc_storage_status set_storage(const evmc::address &addr,
                                    const evmc::bytes32 &key,
                                    const evmc::bytes32 &value) noexcept final;
    evmc::uint256be get_balance(const evmc::address &addr) noexcept final;
    size_t get_code_size(const evmc::address &addr) noexcept final;
    evmc::bytes32 get_code_hash(const evmc::address &addr) noexcept final;
    size_t copy_code(const evmc::address &addr,
                     size_t code_offset,
                     uint8_t *buffer_data,
                     size_t buffer_size) noexcept final;

    void selfdestruct(const evmc::address &addr, const evmc::address &beneficiary) noexcept final;
    evmc::result call(const evmc_message &msg) noexcept final;
    evmc_tx_context get_tx_context() noexcept final;
    evmc::bytes32 get_block_hash(int64_t number) noexcept final;
    void emit_log(const evmc::address &addr,
                  const uint8_t *data,
                  size_t data_size,
                  const evmc::bytes32 topics[],
                  size_t topics_count) noexcept final;
};

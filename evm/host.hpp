/* EVMC: Ethereum Client-VM Connector API.
 * Copyright 2016-2019 The EVMC Authors.
 * Licensed under the Apache License, Version 2.0.
 */

#include <evmc/evmc.hpp>
#include <unordered_map>
#include <utility>
#include <byteswap.h>

#define bread(expr) fread(expr.bytes, sizeof(expr.bytes));
static void fread(void *ptr, size_t size) {
    if (size == 0) return;
    if (fread(ptr, size, 1, stdin) != 1) exit(1);
}
template<typename T>
T iread() {
    T tmp;
    fread(&tmp, sizeof(tmp));
    return tmp;
}

static void fwrite(const void *ptr, size_t size) {fwrite(ptr, size, 1, stdout);}

// Read and write port package size
static void nread() {iread<uint32_t>();}
static void nwrite(uint32_t num) {num = __bswap_32(num); fwrite(&num, sizeof(num));}



namespace std
{
/// Hash operator template specialization for evmc::address. Needed for unordered containers.
template <>
struct hash<pair<evmc::address,evmc::bytes32>>
{
    /// Hash operator using FNV1a-based folding.
    constexpr size_t operator()(const pair<evmc::address, evmc::bytes32>& s) const noexcept
    {
        using namespace evmc;
        using namespace fnv;
        return hash<evmc::address>()(s.first) ^ hash<evmc::bytes32>()(s.second);
    }
};

};

class Host : public evmc::Host
{
    std::unordered_map<std::pair<evmc::address, evmc::bytes32>, evmc::bytes32> m_storage_cache{};
public:
    evmc_tx_context tx_context{};

    Host() = default;
    void reset();
    bool account_exists(const evmc::address& addr) noexcept final;
    bool get_cache(const evmc::address& addr, const evmc::bytes32& key, evmc::bytes32& out) noexcept;
    evmc::bytes32 get_storage(const evmc::address& addr, const evmc::bytes32& key) noexcept final;
    evmc_storage_status set_storage(const evmc::address& addr,
                                    const evmc::bytes32& key,
                                    const evmc::bytes32& value) noexcept final;
    evmc::uint256be get_balance(const evmc::address& addr) noexcept final;
    size_t get_code_size(const evmc::address& addr) noexcept final;
    evmc::bytes32 get_code_hash(const evmc::address& addr) noexcept final;
    size_t copy_code(const evmc::address& addr,
                     size_t code_offset,
                     uint8_t* buffer_data,
                     size_t buffer_size) noexcept final;

    void selfdestruct(const evmc::address& addr, const evmc::address& beneficiary) noexcept final;
    evmc::result call(const evmc_message& msg) noexcept final;
    evmc_tx_context get_tx_context() noexcept final;
    evmc::bytes32 get_block_hash(int64_t number) noexcept final;
    void emit_log(const evmc::address& addr,
                  const uint8_t* data,
                  size_t data_size,
                  const evmc::bytes32 topics[],
                  size_t topics_count) noexcept final;
};
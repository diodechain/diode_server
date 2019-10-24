#include "host.hpp"

#ifdef DEBUG
static char x[] = "0123456789abcdef";
static char* _hex(const uint8_t *p, size_t i) {
    static char buff[65] = {};
    size_t j;
    for(j = 0; j < i; j++) {
        buff[2*j] = x[p[j] / 16];
        buff[2*j+1] = x[p[j] % 16];
    }
    buff[2*j] = 0;
    return buff;
}
#define hex(expr) _hex(expr, sizeof(expr))
#define dlog(format, ...) fprintf(stderr, format, __VA_ARGS__);
#else
#define dlog(format, ...)
#endif

void Host::reset()
{
    m_storage_cache.clear();
}

bool Host::get_cache(const evmc::address& addr, const evmc::bytes32& key, evmc::bytes32& out) noexcept
{
    auto ptr = m_storage_cache.find(std::make_pair(addr, key));
    if (ptr == m_storage_cache.end()) {
        return false;
    } else {
        out = ptr->second;
        return true;
    }
}

bool Host::account_exists(const evmc::address& addr) noexcept
{
    uint64_t ret;

    dlog("account_exists(%s)\n", hex(addr.bytes));
    nwrite(2 + sizeof(addr.bytes));
    fwrite("ae", 2);
    fwrite(addr.bytes, sizeof(addr.bytes));
    fflush(stdout);

    nread();
    fread(&ret, sizeof(ret));
    return ret == 1;
}

evmc::bytes32 Host::get_storage(const evmc::address& addr, const evmc::bytes32& key) noexcept
{
    evmc::bytes32 ret;
    if (get_cache(addr, key, ret)) return ret;

    dlog("get_storage(%s,", hex(addr.bytes));
    dlog("%s)\n", hex(key.bytes));

    nwrite(2 + sizeof(addr.bytes) + sizeof(key.bytes));
    fwrite("gs", 2);
    fwrite(addr.bytes, sizeof(addr.bytes));
    fwrite(key.bytes, sizeof(key.bytes));
    fflush(stdout);

    nread();
    fread(ret.bytes, sizeof(ret.bytes));

    m_storage_cache[std::make_pair(addr, key)] = ret;
    return ret;
}

evmc_storage_status Host::set_storage(const evmc::address& addr,
                                const evmc::bytes32& key,
                                const evmc::bytes32& value) noexcept
{
    evmc::bytes32 prev_value;

    dlog("set_storage(%s)\n", hex(key.bytes));

    nwrite(2 + sizeof(addr.bytes) + sizeof(key.bytes) + sizeof(value.bytes));
    fwrite("ss", 2);
    fwrite(addr.bytes, sizeof(addr.bytes));
    fwrite(key.bytes, sizeof(key.bytes));
    fwrite(value.bytes, sizeof(value.bytes));
    fflush(stdout);

    nread();
    fread(prev_value.bytes, sizeof(prev_value.bytes));

    m_storage_cache[std::make_pair(addr, key)] = value;
    return (prev_value == value) ? EVMC_STORAGE_UNCHANGED : EVMC_STORAGE_MODIFIED;
}

evmc::uint256be Host::get_balance(const evmc::address& addr) noexcept
{
    evmc::uint256be ret;

    dlog("get_balance(%s)\n", hex(addr.bytes));

    nwrite(2 + sizeof(addr.bytes));
    fwrite("gb", 2);
    fwrite(addr.bytes, sizeof(addr.bytes));
    fflush(stdout);

    nread();
    fread(ret.bytes, sizeof(ret.bytes));
    return ret;
}

size_t Host::get_code_size(const evmc::address& addr) noexcept
{
    uint64_t ret;

    dlog("get_code_size(%s)\n", hex(addr.bytes));

    nwrite(2 + sizeof(addr.bytes));
    fwrite("gc", 2);
    fwrite(addr.bytes, sizeof(addr.bytes));
    fflush(stdout);

    nread();
    fread(&ret, sizeof(ret));
    return (size_t)ret;
}

evmc::bytes32 Host::get_code_hash(const evmc::address& addr) noexcept
{
    evmc::bytes32 ret;

    dlog("get_code_hash()\n");

    nwrite(2 + sizeof(addr.bytes));
    fwrite("gd", 2);
    fwrite(addr.bytes, sizeof(addr.bytes));

    nread();
    fread(ret.bytes, sizeof(ret.bytes));
    return ret;
}

size_t Host::copy_code(const evmc::address& addr,
                    size_t code_offset,
                    uint8_t* buffer_data,
                    size_t buffer_size) noexcept
{
    int64_t ret;
    int64_t offset = code_offset;
    int64_t size = buffer_size;

    dlog("copy_code()\n");

    nwrite(2 + sizeof(addr.bytes) + sizeof(offset) + sizeof(size));
    fwrite("cc", 2);
    fwrite(addr.bytes, sizeof(addr.bytes));
    fwrite(&offset, sizeof(offset));
    fwrite(&size, sizeof(size));
    fflush(stdout);

    nread();
    fread(&ret, sizeof(&ret));
    fread(buffer_data, ret);
    return ret;
}

void Host::selfdestruct(const evmc::address& addr, const evmc::address& beneficiary) noexcept
{
    dlog("selfdestruct()\n");

    nwrite(2 + sizeof(addr.bytes) + sizeof(beneficiary.bytes));
    fwrite("sd", 2);
    fwrite(addr.bytes, sizeof(addr.bytes));
    fwrite(beneficiary.bytes, sizeof(beneficiary.bytes));
    fflush(stdout);
}

void delete_output(const evmc_result* result)
{
    delete[] result->output_data;
}

evmc::result Host::call(const evmc_message& msg) noexcept
{
    int64_t kind = msg.kind;

    dlog("call()\n");

    nwrite(2 + sizeof(kind) + sizeof(msg.sender.bytes) + sizeof(msg.destination.bytes)
        + sizeof(msg.value.bytes) + sizeof(msg.input_size) + msg.input_size
        + sizeof(msg.gas));
    fwrite("ca", 2);
    fwrite(&kind, sizeof(kind));
    fwrite(msg.sender.bytes, sizeof(msg.sender.bytes));
    fwrite(msg.destination.bytes, sizeof(msg.destination.bytes));
    fwrite(msg.value.bytes, sizeof(msg.value.bytes));
    fwrite(&msg.input_size, sizeof(msg.input_size));
    fwrite(msg.input_data, msg.input_size);
    fwrite(&msg.gas, sizeof(msg.gas));
    fflush(stdout);

    evmc_result ret;
    nread();
    ret.gas_left = iread<int64_t>();
    ret.status_code = static_cast<evmc_status_code>(iread<int64_t>());
    ret.output_size = iread<uint64_t>();
    auto output_data = new uint8_t[ret.output_size]();
    fread(output_data, ret.output_size);
    ret.output_data = output_data;
    bread(ret.create_address);


    ret.release = delete_output;
    return evmc::result(ret);
}

evmc_tx_context Host::get_tx_context() noexcept 
{ 
    return tx_context; 
}

evmc::bytes32 Host::get_block_hash(int64_t number) noexcept
{
    evmc::bytes32 ret;

    dlog("get_block_hash(%ld)\n", number);

    nwrite(2 + sizeof(number));
    fwrite("gh", 2);
    fwrite(&number, sizeof(number));
    fflush(stdout);

    nread();
    fread(ret.bytes, sizeof(ret.bytes));
    return ret;
}

void Host::emit_log(const evmc::address& addr,
                const uint8_t* data,
                size_t data_size,
                const evmc::bytes32 topics[],
                size_t topics_count) noexcept
{
    int64_t size = data_size;
    int64_t count = topics_count;

    dlog("emit_log()\n");

    nwrite(2 + sizeof(addr.bytes) + sizeof(size) + size 
        + sizeof(count) + count * sizeof(topics[0].bytes));
    fwrite("lo", 2);
    fwrite(addr.bytes, sizeof(addr.bytes));
    fwrite(&size, sizeof(size));
    fwrite(data, data_size);
    fwrite(&count, sizeof(count));
    for (int64_t i = 0; i < count; i++)
        fwrite(topics[i].bytes, sizeof(topics[i].bytes));
    fflush(stdout);
}

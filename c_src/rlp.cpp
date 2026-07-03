#include "rlp.hpp"
// Encode-only subset of lib/rlp.ex for account hashing inside dirty NIFs.
#include <cstring>

static void append_length_prefix(uint8_t offset, size_t size, const uint8_t *data, std::vector<uint8_t> &out)
{
    if (size <= 55) {
        out.push_back((uint8_t)(offset + size));
        if (size > 0) {
            out.insert(out.end(), data, data + size);
        }
    } else {
        uint8_t len_bytes[8];
        size_t len_size = 0;
        size_t tmp = size;
        while (tmp > 0) {
            len_bytes[len_size++] = (uint8_t)(tmp & 0xFF);
            tmp >>= 8;
        }
        for (size_t i = 0; i < len_size / 2; i++) {
            uint8_t swap = len_bytes[i];
            len_bytes[i] = len_bytes[len_size - 1 - i];
            len_bytes[len_size - 1 - i] = swap;
        }
        out.push_back((uint8_t)(offset + 55 + len_size));
        out.insert(out.end(), len_bytes, len_bytes + len_size);
        out.insert(out.end(), data, data + size);
    }
}

void rlp_encode_bytes(const uint8_t *data, size_t len, std::vector<uint8_t> &out)
{
    if (len == 1 && data[0] < 0x80) {
        out.push_back(data[0]);
        return;
    }
    append_length_prefix(0x80, len, data, out);
}

void rlp_encode_uint64(uint64_t value, std::vector<uint8_t> &out)
{
    if (value == 0) {
        rlp_encode_bytes(nullptr, 0, out);
        return;
    }
    uint8_t bytes[8];
    size_t len = 0;
    uint64_t tmp = value;
    while (tmp > 0) {
        bytes[len++] = (uint8_t)(tmp & 0xFF);
        tmp >>= 8;
    }
    for (size_t i = 0; i < len / 2; i++) {
        uint8_t swap = bytes[i];
        bytes[i] = bytes[len - 1 - i];
        bytes[len - 1 - i] = swap;
    }
    rlp_encode_bytes(bytes, len, out);
}

void rlp_encode_list(const std::vector<uint8_t> &item0, const std::vector<uint8_t> &item1,
        const std::vector<uint8_t> &item2, const std::vector<uint8_t> &item3,
        std::vector<uint8_t> &payload, std::vector<uint8_t> &out)
{
    payload.clear();
    payload.insert(payload.end(), item0.begin(), item0.end());
    payload.insert(payload.end(), item1.begin(), item1.end());
    payload.insert(payload.end(), item2.begin(), item2.end());
    payload.insert(payload.end(), item3.begin(), item3.end());
    append_length_prefix(0xC0, payload.size(), payload.data(), out);
}

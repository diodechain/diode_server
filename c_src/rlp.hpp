#ifndef RLP_HPP
#define RLP_HPP

#include <cstdint>
#include <vector>

void rlp_encode_bytes(const uint8_t *data, size_t len, std::vector<uint8_t> &out);
void rlp_encode_uint64(uint64_t value, std::vector<uint8_t> &out);
void rlp_encode_list(const std::vector<uint8_t> &item0, const std::vector<uint8_t> &item1,
        const std::vector<uint8_t> &item2, const std::vector<uint8_t> &item3,
        std::vector<uint8_t> &payload, std::vector<uint8_t> &out);

#endif

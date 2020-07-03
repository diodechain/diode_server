// EVMC Wrapper
// Copyright 2019 IoT Blockchain Technology Corporation LLC (IBTC)
// Licensed under the GNU General Public License, Version 3.
#include "libaleth-interpreter/interpreter.h"
#include "libaleth-interpreter/VM.h"
#include <evmc/evmc.hpp>
#include "host.hpp"

using namespace dev::eth;

int main() {
    evmc_vm* vm = evmc_create_interpreter();
    Host host;

    bool run = true;
    while(!feof(stdin) && run) {
        nread();
        char cmd = getc(stdin);
        if (cmd == 'c') { // 'c' ==> Create context
            dlog("create_context()\n");
            host.reset();
            // evmc_uint256be tx_gas_price;     /**< The transaction gas price. */
            bread(host.tx_context.tx_gas_price);
            // evmc_address tx_origin;          /**< The transaction origin account. */
            bread(host.tx_context.tx_origin);
            // evmc_address block_coinbase;     /**< The miner of the block. */
            bread(host.tx_context.block_coinbase);
            // int64_t block_number;            /**< The block number. */
            host.tx_context.block_number = iread<int64_t>();
            // int64_t block_timestamp;         /**< The block timestamp. */
            host.tx_context.block_timestamp = iread<int64_t>();
            // int64_t block_gas_limit;         /**< The block gas limit. */
            host.tx_context.block_gas_limit = iread<int64_t>();
            // evmc_uint256be block_difficulty; /**< The block difficulty. */
            bread(host.tx_context.block_difficulty);
            // evmc_uint256be chain_id;         /**< The blockchain's ChainID. */
            bread(host.tx_context.chain_id);
        } else if (cmd == 'p') { // 'p' ==> Pre-Seed cache data
            dlog("preseed_cache()\n");
            auto count = iread<uint32_t>();
            evmc_address address;
            bread(address);

            for (uint32_t i = 0; i < count; i++) {
                evmc_bytes32 key;
                evmc_bytes32 value;

                bread(key);
                bread(value);
                host.set_cache(address, key, value);
            }
            host.set_complete_account(address);

        } else if (cmd == 'r') { // 'r' ==> Run context
            dlog("run_context()\n");
            struct evmc_message msg{};
            msg.kind = EVMC_CALL;

            bread(msg.sender);
            // msg.sender = addr;
            bread(msg.destination);
            // msg.destination = addr;
            bread(msg.value);
            // msg.value = value;

            msg.input_size = iread<int64_t>();
            std::vector<uint8_t> data(msg.input_size);
            fread(data.data(), msg.input_size);
            msg.input_data = data.data();

            msg.gas = iread<int64_t>();
            msg.depth = iread<int32_t>();

            int64_t code_size = iread<int64_t>();
            std::vector<uint8_t> code(code_size);
            fread(code.data(), code_size);

            evmc_result ret = vm->execute(vm, &host, EVMC_CONSTANTINOPLE, &msg, code.data(), code_size);
            host.send_updates();
            
            int64_t ref_size = ret.output_size;
            int64_t gas_left = ret.gas_left;
            int64_t ret_code = ret.status_code;

            nwrite(2 + sizeof(gas_left) + sizeof(ret_code) + sizeof(ref_size) + ref_size);
            fwrite("ok", 2);
            fwrite(&gas_left, sizeof(gas_left));
            fwrite(&ret_code, sizeof(ret_code));
            fwrite(&ref_size, sizeof(ref_size));
            fwrite(ret.output_data, ref_size);
            fflush(stdout);
            if (ret.release) {
                ret.release(&ret);
            }
        } else if (cmd == 'q' || cmd == EOF) {
            run = false;
        }
    }
    return 0;
}
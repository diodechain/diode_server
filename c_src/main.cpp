#include "merkletree.hpp"
#include <iostream>
#include <chrono>

int test0() {
    bits_t bits;

    bits.push_back(true);
    if (bits.byte(0) != 128) {
        std::cout << "test0[1]: bits.value()[0] != 128" << std::endl;
        std::cout << "bits.value()[0]: " << (int)bits.byte(0) << std::endl;
        return 1;
    }
    bits.push_back(true);
    if (bits.byte(0) != 192) {
        std::cout << "test0[2]: bits.value[0] != 192" << std::endl;
        std::cout << "bits.value()[0]: " << (int)bits.byte(0) << std::endl;
        return 1;
    }

    bits.push_back(false);
    if (bits.byte(0) != 192) {
        std::cout << "test0[3]: bits.value[0] != 192" << std::endl;
        std::cout << "bits.value()[0]: " << (int)bits.byte(0) << std::endl;
        return 1;
    }

    bits.push_back(true);
    if (bits.byte(0) != 208) {
        std::cout << "test0[4]: bits.value[0] != 208" << std::endl;
        return 1;
    }

    return 0;
}

int test_assert(Tree &tree, size_t size, std::string ref) {
    if (tree.size() != size) {
        std::cout << "tree.size() != size: " << tree.size() << " != " << size << std::endl;
        return 1;
    }

    auto root_hash = tree.root_hash();
    if (root_hash.hex() != ref) {
        std::cout << "root_hash(" << std::dec << size << ") != ref: " << root_hash.hex() << " != " << ref << std::endl;
        return 1;
    }

    std::cout << "root_hash(" << std::dec << size << ") == ref" << std::endl;
    return 0;
}

std::vector<uint256_t> test_data(int size, const char *format = "!%d!") {
    std::vector<uint256_t> testdata;
    testdata.reserve(size);
    bin_t buffer;

    for (int i = 0; i < size; i++) {
        buffer.resize(128);
        sprintf((char*)buffer.data(), format, i+1);
        auto len = strlen((char*)buffer.data());
        buffer.resize(len);
        uint256_t key = hash(buffer);
        testdata.push_back(key);
    }

    return testdata;
}


int test2(int size, std::string ref) {
    Tree tree;
    auto testdata = test_data(size);

    for (uint256_t &key : testdata) {
        auto bkey = bin_t(key.data(), key.data() + 32);
        tree.insert_item(bkey, key);
    }

    return test_assert(tree, size, ref);
}

int test3(int size, std::string ref, int change_size) {
    Tree tree;
    auto testdata = test_data(size);
    auto changes = test_data(change_size, "x%dx");

    for (uint256_t &key : testdata) {
        auto bkey = bin_t(key.data(), key.data() + 32);
        tree.insert_item(bkey, key);
    }

    for (uint256_t &key : changes) {
        auto bkey = bin_t(key.data(), key.data() + 32);
        tree.insert_item(bkey, key);
    }

    auto root_hash = tree.root_hash();
    if (root_hash.hex() == ref) {
        std::cout << "root_hash + changes(" << std::dec << size << ") == ref" << std::endl;
        return 0;
    }

    if (tree.size() != size_t(size + change_size)) {
        std::cout << "tree.size() != size + change_size: " << tree.size() << " != " << size + change_size << std::endl;
        return 1;
    }

    for (uint256_t &key : changes) {
        auto bkey = bin_t(key.data(), key.data() + 32);
        pair_t ret = tree.get_item(bkey);
        if (ret.key != bkey) {
            std::cout << "tree.get_item(" << key.hex() << ") != " << key.hex() << std::endl;
            return 1;
        }
        tree.delete_item(bkey);
    }

    return test_assert(tree, size, ref);
}

int bench(int size, std::string ref) {
    auto testdata = test_data(size);

    for (int i = 0; i < 3; i++) {
        auto start = std::chrono::steady_clock::now();

        for (int j = 0; j < 1000000/size; j++) {
            Tree tree;

            for (uint256_t &key : testdata) {
                auto bkey = bin_t(key.data(), key.data() + 32);
                tree.insert_item(bkey, key);
            }

            auto root_hash = tree.root_hash();
            if (root_hash.hex() != ref) {
                std::cout << "root_hash(" << std::dec << size << ") != ref: " << root_hash.hex() << " != " << ref << std::endl;
                return 1;
            }
        }

        auto end = std::chrono::steady_clock::now();
        auto ms = std::chrono::duration_cast<std::chrono::milliseconds>(end - start);
        std::cout << "Run(" << size << ") " << i << ": " << ms.count() << "ms " << std::endl;
    }

    std::cout << "bench done!" << std::endl;
    return 0;
}

int main(int argc, char *argv[]) {
    if (argc > 1 && argv[1] == std::string("bench")) {
        // bench(10000, "0x96c2b5d03aa8e52230e74d9a08359c38c7608e5d9aba18773f3c90baf3806ccb");
        bench(1, "0x5d70256ffdf5745e05fd4917ab229d27b690fa7f587918c7494c93520bd1e284");
        bench(100, "0x784330a04291e879b7893ce55534d390931e6047bdf8b7fdc56e0d0f8a5b4c52");
        bench(100000, "0x3b99d56aa16278d50e85a8ea0939e62180c4f0305b773775f1844c3303a41897");
        return 0;
    }

    if (test0()) return 1;
    if (test2(0, "0x438a90405daa876539082cd0baf6cddaa3bf880f1c8af0c0381f0042db93088a")) return 1;
    if (test2(16, "0x9fec182245843e74cfa3f567d3b4aa050f7f7c632170bc2f5e7d3f98d6d0894c")) return 1;
    if (test2(20, "0x946d279e3fb07bd2824981c07a04889487c878d6b57a2edef69546ecf3a7b00d")) return 1;
    if (test2(128, "0x4366a22bf46f821e5693d1835f0a863415d23910f9cffa54a65776f1b79ea8ae")) return 1;
    if (test2(1024, "0xcad280c10f8529ad36bce8e3b03a464987c6d4286c21bfcba0a76acd237e9025")) return 1;
    if (test3(1024, "0xcad280c10f8529ad36bce8e3b03a464987c6d4286c21bfcba0a76acd237e9025", 18)) return 1;
    if (test3(1024, "0xcad280c10f8529ad36bce8e3b03a464987c6d4286c21bfcba0a76acd237e9025", 128)) return 1;
    // if (test2(1000000, "0x3f7fc2e10181d3936167cf16dbb8efd40f9d8703402c630a95eb1182bd0dcc70")) return 1;
    // printf("hash_count: %d\n", hash_count);
    return 0;
}


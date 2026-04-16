#include "merkletree.hpp"
#include "item_pool.hpp"

#include <cassert>
#include <cstring>
#include <mutex>

std::shared_ptr<ItemPool> ItemPool::make() {
    return std::shared_ptr<ItemPool>(new ItemPool());
}

ItemPool::~ItemPool() = default;

ItemPool::ItemPool() {
    nodes.emplace_back(nullptr);
    refcnt.emplace_back(0);
}

void ItemPool::ensure_slot(ItemId id) {
    if (id >= nodes.size()) {
        nodes.resize(id + 1);
        refcnt.resize(id + 1, 0);
    }
}

Item *ItemPool::get(ItemId id) {
    std::lock_guard<std::recursive_mutex> lock(mtx);
    if (id == kItemNull) {
        return nullptr;
    }
    assert(id < nodes.size() && nodes[id]);
    return nodes[id].get();
}

const Item *ItemPool::get(ItemId id) const {
    std::lock_guard<std::recursive_mutex> lock(mtx);
    if (id == kItemNull) {
        return nullptr;
    }
    assert(id < nodes.size() && nodes[id]);
    return nodes[id].get();
}

void ItemPool::incr_ref_nolock(ItemId id) {
    if (id == kItemNull) {
        return;
    }
    refcnt[id]++;
}

void ItemPool::incr_ref(ItemId id) {
    std::lock_guard<std::recursive_mutex> lock(mtx);
    incr_ref_nolock(id);
}

void ItemPool::decr_ref(ItemId id) {
    std::lock_guard<std::recursive_mutex> lock(mtx);
    if (id == kItemNull) {
        return;
    }
    assert(refcnt[id] > 0);
    refcnt[id]--;
    if (refcnt[id] > 0) {
        return;
    }
    Item *it = nodes[id].get();
    ItemId L = it->left_id;
    ItemId R = it->right_id;
    decr_ref(L);
    decr_ref(R);
    nodes[id].reset();
    free_list.push_back(id);
}

ItemId ItemPool::alloc_leaf_nolock(Tree &tree) {
    ItemId id;
    if (!free_list.empty()) {
        id = free_list.back();
        free_list.pop_back();
        ensure_slot(id);
    } else {
        id = (ItemId)nodes.size();
        nodes.emplace_back();
        refcnt.push_back(0);
    }
    nodes[id] = std::unique_ptr<Item>(new Item(tree));
    refcnt[id] = 0;
    return id;
}

ItemId ItemPool::alloc_leaf(Tree &tree) {
    std::lock_guard<std::recursive_mutex> lock(mtx);
    return alloc_leaf_nolock(tree);
}

ItemId ItemPool::create_root(Tree &tree) {
    std::lock_guard<std::recursive_mutex> lock(mtx);
    ItemId id = alloc_leaf_nolock(tree);
    incr_ref_nolock(id);
    return id;
}

bool ItemPool::is_unique(ItemId id) const {
    std::lock_guard<std::recursive_mutex> lock(mtx);
    if (id == kItemNull) {
        return true;
    }
    assert(id < refcnt.size());
    return refcnt[id] <= 1;
}

ItemId ItemPool::clone_for_fork(ItemId id, Tree &tree) {
    std::lock_guard<std::recursive_mutex> lock(mtx);
    const Item *src = nodes[id].get();
    assert(src);
    ItemId nid = alloc_leaf_nolock(tree);
    Item *dst = nodes[nid].get();
    delete dst->leaf_bucket;
    dst->leaf_bucket = nullptr;
    dst->is_leaf = src->is_leaf;
    dst->dirty = true;
    dst->hash_count = src->hash_count;
    dst->prefix = src->prefix;
    if (src->hash_values) {
        dst->hash_values = new uint256_t[LEAF_SIZE];
        std::memcpy(dst->hash_values, src->hash_values, LEAF_SIZE * sizeof(uint256_t));
    }
    if (src->leaf_bucket) {
        dst->leaf_bucket = clone_pair_list(src->leaf_bucket, tree);
    }
    dst->left_id = src->left_id;
    dst->right_id = src->right_id;
    incr_ref_nolock(dst->left_id);
    incr_ref_nolock(dst->right_id);
    return nid;
}

void ItemPool::set_left(ItemId parent, ItemId child) {
    std::lock_guard<std::recursive_mutex> lock(mtx);
    Item *p = nodes[parent].get();
    if (p->left_id == child) {
        return;
    }
    decr_ref(p->left_id);
    p->left_id = child;
    incr_ref_nolock(child);
}

void ItemPool::set_right(ItemId parent, ItemId child) {
    std::lock_guard<std::recursive_mutex> lock(mtx);
    Item *p = nodes[parent].get();
    if (p->right_id == child) {
        return;
    }
    decr_ref(p->right_id);
    p->right_id = child;
    incr_ref_nolock(child);
}

size_t ItemPool::live_nodes() const {
    std::lock_guard<std::recursive_mutex> lock(mtx);
    size_t n = 0;
    for (size_t i = 1; i < nodes.size(); i++) {
        if (nodes[i]) {
            n++;
        }
    }
    return n;
}

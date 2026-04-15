#ifndef ITEM_POOL_HPP
#define ITEM_POOL_HPP

#include <cstdint>
#include <memory>
#include <vector>

class Tree;
struct Item;

using ItemId = uint32_t;
static constexpr ItemId kItemNull = 0;

/**
 * Owns trie nodes (Item). Reference counts mirror incoming edges: each parent slot
 * (Tree::root_id, Item::left_id, Item::right_id) that points to id contributes +1.
 * fork_for_write clones when refcnt > 1 (shared node).
 *
 * Refcount updates are not synchronized here: the Erlang NIF holds SharedState::mtx
 * (see nif.cpp Lock) across mutations, so plain uint32_t refcnt is sufficient.
 */
class ItemPool {
public:
    static std::shared_ptr<ItemPool> make();

    ~ItemPool();

    Item *get(ItemId id);
    const Item *get(ItemId id) const;

    /** New leaf node (empty bucket); refcnt starts at 0 — caller links via set_left/set_right/root. */
    ItemId alloc_leaf(Tree &tree);

    /** Decrement ref; when zero, recursively release children and free slot. */
    void decr_ref(ItemId id);

    void incr_ref(ItemId id);

    /** Copy node payload and share child ids (+1 ref each child). New node refcnt 0 until linked. */
    ItemId clone_for_fork(ItemId id, Tree &tree);

    void set_left(ItemId parent, ItemId child);
    void set_right(ItemId parent, ItemId child);

    /** First root node for a new tree (refcnt 1). */
    ItemId create_root(Tree &tree);

    /** True if this node is only referenced from one incoming edge (safe to mutate in place). */
    bool is_unique(ItemId id) const;

    size_t live_nodes() const;

#ifdef MERKLE_DEBUG_POOL
    void invariant_check(ItemId root) const;
#endif

private:
    ItemPool();

    std::vector<std::unique_ptr<Item>> nodes; // index = ItemId; [0] unused
    std::vector<uint32_t> refcnt;
    std::vector<ItemId> free_list;

    void ensure_slot(ItemId id);
};

#endif

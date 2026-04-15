#ifndef PREALLOCATOR_HPP
#define PREALLOCATOR_HPP

#include <list>
#include <cstdint>
#include <cstdlib>
#include <mutex>

class Tree;

#ifndef MERKLE_STRIPE_SIZE
#define MERKLE_STRIPE_SIZE 8
#endif

template<typename T>
class GlobalStripePool {
    inline static std::mutex s_mtx;
    inline static std::list<uint8_t *> s_stripes;

public:
    static uint8_t *take() {
        std::lock_guard<std::mutex> lock(s_mtx);
        if (s_stripes.empty()) {
            return nullptr;
        }
        uint8_t *p = s_stripes.front();
        s_stripes.pop_front();
        return p;
    }

    static void put(uint8_t *stripe) {
        std::lock_guard<std::mutex> lock(s_mtx);
        s_stripes.push_back(stripe);
    }
};

template<typename T>
class PreAllocator {
    static constexpr size_t STRIPE_SIZE = MERKLE_STRIPE_SIZE;
    Tree &m_tree;
    std::list<uint8_t*> m_stripes;
    size_t m_item_count;
    std::list<T*> m_backbuffer;

public:
    PreAllocator(Tree &tree) : m_tree(tree), m_item_count(0) { }
    ~PreAllocator() {
        for (uint8_t *stripe : m_stripes) {
            auto len = std::min(STRIPE_SIZE, m_item_count);
            for (size_t i = 0; i < len; i++) {
                T* item = reinterpret_cast<T*>(&stripe[(i % STRIPE_SIZE) * sizeof(T)]);
                item->~T();
            }
            m_item_count -= len;
            GlobalStripePool<T>::put(stripe);
        }
    }

    T* new_item() {
        if (!m_backbuffer.empty()) {
            T* item = m_backbuffer.front();
            m_backbuffer.pop_front();
            return item;
        }

        if (m_item_count + 1 > m_stripes.size() * STRIPE_SIZE) {
            uint8_t *block = GlobalStripePool<T>::take();
            if (!block) {
                block = (uint8_t *)malloc(STRIPE_SIZE * sizeof(T));
            }
            m_stripes.push_back(block);
        }

        T* item = reinterpret_cast<T*>(&m_stripes.back()[(m_item_count % STRIPE_SIZE) * sizeof(T)]);
        m_item_count++;
        return new (item) T(m_tree);
    }

    void destroy_item(T* item) {
        item->~T();
        m_backbuffer.push_back(new (item) T(m_tree));
    }
};

#endif
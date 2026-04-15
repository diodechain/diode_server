# OPTS=merkletree.cpp sha.cpp -O3 -march=native -msha -Wall -Wextra -pedantic -lstdc++ -fsanitize=address -ggdb3
OPTS=merkletree.cpp item_pool.cpp sha.cpp -g -O3 -march=native -msha -Wall -Wextra -pedantic -lstdc++
ERL_INCLUDE_PATH = $(shell erl -eval 'io:format("~s", [lists:concat([code:root_dir(), "/erts-", erlang:system_info(version), "/include"])])' -s init stop -noshell)
CFLAGS+=-I. -O2 -g -Wall -Wno-unknown-pragmas
CXXFLAGS+=-std=c++17 $(CFLAGS)

UNAME_S := $(shell uname -s)

ifeq ($(UNAME_S),Darwin)
	OPTS+=-undefined dynamic_lookup
endif

.PHONY: test
test:
	$(CXX) -o test main.cpp ${OPTS}
	./test

.PHONY: bench
bench:
	$(CXX) -o test main.cpp ${OPTS}
	./test bench

# Optional: larger slab stripes — rebuild NIF with e.g. CXXFLAGS=-DMERKLE_STRIPE_SIZE=32 make -C c_src nif
.PHONY: mem_harness
mem_harness: mem_harness.bin
	./mem_harness.bin $(MERKLE_N)

mem_harness.bin: mem_harness.cpp merkletree.hpp merkletree.cpp item_pool.cpp sha.cpp Makefile
	$(CXX) $(CXXFLAGS) -o mem_harness.bin mem_harness.cpp ${OPTS}

.PHONY: nif
nif: ../priv/merkletree_nif.so

../priv/merkletree_nif.so: nif.cpp merkletree.hpp merkletree.cpp item_pool.cpp sha.cpp preallocator.hpp Makefile
	echo ${ERL_INCLUDE_PATH}
	mkdir -p ../priv
	$(CXX) $(CXXFLAGS) -I${ERL_INCLUDE_PATH} -o ../priv/merkletree_nif.so -shared -fPIC nif.cpp ${OPTS}

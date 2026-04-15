# OPTS=merkletree.cpp sha.cpp -O3 -march=native -msha -Wall -Wextra -pedantic -lstdc++ -fsanitize=address -ggdb3
# Hardened release example (reproducible CPU, RELRO+BIND_NOW): append to link line, e.g.
#   LDFLAGS=-Wl,-z,relro,-z,now make nif CXXFLAGS='$(CXXFLAGS) -D_FORTIFY_SOURCE=2 -fstack-protector-strong' OPTS='merkletree.cpp item_pool.cpp sha.cpp -O2 -march=x86-64 -msha -Wall -Wextra -pedantic -lstdc++'
OPTS=merkletree.cpp item_pool.cpp sha.cpp -g -O3 -march=native -msha -Wall -Wextra -pedantic -lstdc++
# AddressSanitizer / UndefinedBehaviorSanitizer (use: make -C c_src test-asan nif-asan)
SANFLAGS=-fsanitize=address,undefined -fno-omit-frame-pointer -g
OPTS_ASAN=merkletree.cpp item_pool.cpp sha.cpp -O1 -march=native -msha -Wall -Wextra -pedantic $(SANFLAGS) -lstdc++
ERL_INCLUDE_PATH = $(shell erl -eval 'io:format("~s", [lists:concat([code:root_dir(), "/erts-", erlang:system_info(version), "/include"])])' -s init stop -noshell)
CFLAGS+=-I. -O2 -g -Wall -Wno-unknown-pragmas
CXXFLAGS+=-std=c++17 $(CFLAGS)

UNAME_S := $(shell uname -s)

ifeq ($(UNAME_S),Darwin)
	OPTS+=-undefined dynamic_lookup
	OPTS_ASAN+=-undefined dynamic_lookup
endif

.PHONY: test test-asan
test:
	$(CXX) -o test main.cpp ${OPTS}
	./test

# Native tests + difference_stress under ASan/UBSan (no Elixir).
# detect_leaks=0: GlobalStripePool / process exit keeps slab allocations (noise for LSan).
test-asan:
	$(CXX) -o test_asan main.cpp $(OPTS_ASAN)
	ASAN_OPTIONS=detect_leaks=0:abort_on_error=1:halt_on_error=1 ./test_asan diffstress
	ASAN_OPTIONS=detect_leaks=0:abort_on_error=1:halt_on_error=1 ./test_asan

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

# Optional: libFuzzer + ASan on SHA (requires Clang with fuzzer runtime)
.PHONY: nif nif-asan fuzz_sha
fuzz_sha: fuzz_sha.bin
	./fuzz_sha.bin -runs=5000

fuzz_sha.bin: fuzz_sha.cpp sha.cpp Makefile
	clang++ -std=c++17 -I. -g -O1 -fsanitize=fuzzer,address -fno-omit-frame-pointer -o fuzz_sha.bin fuzz_sha.cpp sha.cpp -lstdc++

nif: ../priv/merkletree_nif.so

../priv/merkletree_nif.so: nif.cpp merkletree.hpp merkletree.cpp item_pool.cpp sha.cpp preallocator.hpp Makefile
	echo ${ERL_INCLUDE_PATH}
	mkdir -p ../priv
	$(CXX) $(CXXFLAGS) -I${ERL_INCLUDE_PATH} -o ../priv/merkletree_nif.so -shared -fPIC nif.cpp ${OPTS}

# Instrumented NIF for debugging heap issues (copy over priv/merkletree_nif.so or set in test script).
../priv/merkletree_nif.asan.so: nif.cpp merkletree.hpp merkletree.cpp item_pool.cpp sha.cpp preallocator.hpp Makefile
	echo ${ERL_INCLUDE_PATH}
	mkdir -p ../priv
	$(CXX) $(CXXFLAGS) $(SANFLAGS) -I${ERL_INCLUDE_PATH} -o $@ -shared -fPIC nif.cpp $(OPTS_ASAN)

nif-asan: ../priv/merkletree_nif.asan.so

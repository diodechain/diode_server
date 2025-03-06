# OPTS=merkletree.cpp sha.cpp -O3 -march=native -msha -Wall -Wextra -pedantic -lstdc++ -fsanitize=address -ggdb3
OPTS=merkletree.cpp sha.cpp -g -O3 -march=native -msha -Wall -Wextra -pedantic -lstdc++
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

.PHONY: nif
nif: ../priv/merkletree_nif.so

../priv/merkletree_nif.so: nif.cpp merkletree.hpp merkletree.cpp sha.cpp Makefile
	echo ${ERL_INCLUDE_PATH}
	mkdir -p ../priv
	$(CXX) $(CXXFLAGS) -I${ERL_INCLUDE_PATH} -o ../priv/merkletree_nif.so -shared -fPIC nif.cpp ${OPTS}

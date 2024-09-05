OPTS=merkletree.cpp sha.c -O3 -march=native -msha -Wall -Wextra -pedantic -lstdc++
ERL_INCLUDE_PATH = $(shell erl -eval 'io:format("~s", [lists:concat([code:root_dir(), "/erts-", erlang:system_info(version), "/include"])])' -s init stop -noshell)

.PHONY: test
test:
	gcc -o test main.cpp ${OPTS} -fopenmp
	./test

.PHONY: bench
bench:
	gcc -o test main.cpp ${OPTS} -fopenmp
	./test bench



.PHONY: nif
nif:
	echo ${ERL_INCLUDE_PATH}
	mkdir -p ../priv
	gcc -I${ERL_INCLUDE_PATH} -o ../priv/merkletree_nif.so -shared -fPIC nif.cpp ${OPTS}

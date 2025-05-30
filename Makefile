# Diode Server
# Copyright 2021-2024 Diode
# Licensed under the Diode License, Version 1.1
SHELL := /bin/bash
TESTS := $(wildcard test/*_test.exs)
TESTDATA := test/pems/device1_certificate.pem test/pems/device2_certificate.pem

.PHONY: all
all: evm/evm priv/merkletree_nif.so

priv/merkletree_nif.so: $(wildcard c_src/*.cpp c_src/*.hpp)
	$(MAKE) -C c_src nif

evm/evm: $(wildcard evm/*.cpp evm/*.hpp evm/*/*.cpp evm/*/*.hpp)
	$(MAKE) -C evm

.PHONY: clean
clean:
	$(MAKE) -C evm clean

.PHONY: test
test: $(TESTDATA)
	-rm -rf data_test/ clones/
	$(MAKE) --no-print-directory $(TESTS)

secp256k1_params.pem:
	openssl ecparam -name secp256k1 -out secp256k1_params.pem

test/pems:
	mkdir -p test/pems

%.pem: secp256k1_params.pem test/pems
	openssl req -newkey ec:./secp256k1_params.pem -nodes -keyout $@ -x509 -days 365 -out $@ -subj "/CN=device"

.PHONY: $(TESTS)
$(TESTS):
	# bug in mix, should be auto-compiled
	MIX_ENV=test mix deps.compile profiler
	mix test --max-failures 1 $@

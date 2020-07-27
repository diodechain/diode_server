# Diode Server
# Copyright 2019 IoT Blockchain Technology Corporation LLC (IBTC)
# Licensed under the Diode License, Version 1.0
SHELL := /bin/bash
TESTS := $(wildcard test/*_test.exs)

evm/evm: $(wildcard evm/*.cpp evm/*.hpp evm/*/*.cpp evm/*/*.hpp)
	make -j -C evm

.PHONY: clean
clean:
	make -C evm clean

.PHONY: test $(TESTS)
test:
	-rm -rf data_test/ clones/
	make --no-print-directory $(TESTS)

.PHONY: $(TESTS)
$(TESTS):
	# bug in mix, should be auto-compiled
	MIX_ENV=test mix deps.compile profiler
	mix test $@

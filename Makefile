# Diode Server
# Copyright 2019 IoT Blockchain Technology Corporation LLC (IBTC)
# Licensed under the Diode License, Version 1.0
SHELL := /bin/bash
TESTS := $(wildcard test/*_test.exs)

evm/evm: $(wildcard evm/**)
	$(MAKE) -j -C evm

.PHONY: clean
clean:
	$(MAKE) -C evm clean

.PHONY: test $(TESTS)
test:
	-rm -rf data_test/ clones/
	$(MAKE) --no-print-directory $(TESTS)

.PHONY: $(TESTS)
$(TESTS):
	# bug in mix, should be auto-compiled
	MIX_ENV=test mix deps.compile profiler
	mix test $@

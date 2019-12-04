# Diode Server
# Copyright 2019 IoT Blockchain Technology Corporation LLC (IBTC)
# Licensed under the Diode License, Version 1.0
.PHONY: evm/evm
evm/evm:
	$(MAKE) -j -C evm

.PHONY: clean
clean:
	$(MAKE) -C evm clean

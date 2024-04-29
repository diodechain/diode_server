# EVMC Wrapper
# Copyright 2021-2024 Diode
# Licensed under the GNU General Public License, Version 3.
CFLAGS+=-I. -O2 -g -Wall -Wno-unknown-pragmas
CXXFLAGS+=-std=c++17 $(CFLAGS)
LDFLAGS+=-lboost_system
INTERP=libaleth-interpreter

DEPS  = $(INTERP)/VMOpt.o $(INTERP)/VM.o $(INTERP)/VMCalls.o
DEPS += intx/div.o
DEPS += evmc/instruction_metrics.o
DEPS += ethash/keccak.o ethash/keccakf1600.o

ifneq ($(OS),Windows_NT)
	OS_S := $(shell uname)
	ifeq ($(OS_S), Darwin)
		CFLAGS+=-I./mac
	endif
endif

evm: $(DEPS) main.o host.o
	g++ $^ $(LDFLAGS) -o evm


main.o: host.hpp main.cpp
host.o: host.hpp host.cpp

%.o : %.cpp
	g++ -c $(CXXFLAGS) $< -o $@

%.o : %.c
	gcc -c $(CFLAGS) $< -o $@

.PHONY: clean
clean:
	-rm evm $(DEPS) main.o host.o


CXXFLAGS=-I. -O3 -g -Wall -Wno-unknown-pragmas
LDFLAGS=-lboost_system
INTERP=libaleth-interpreter

DEPS  = $(INTERP)/VMOpt.o $(INTERP)/VM.o $(INTERP)/VMCalls.o 
DEPS += intx/div.o
DEPS += evmc/instruction_metrics.o
DEPS += ethash/keccak.o ethash/keccakf1600.o

all: $(DEPS) main.o host.o
	g++ $^ $(LDFLAGS) -o evm


main.o: host.hpp
host.o: host.hpp

%.o : %.cpp
	g++ -c $(CXXFLAGS) $< -o $@

%.o : %.c
	gcc -c $(CXXFLAGS) $< -o $@

.PHONY: clean
clean:
	rm $(DEPS)
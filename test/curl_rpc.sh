#!/bin/bash
# Diode Server
# Copyright 2021-2024 Diode
# Licensed under the Diode License, Version 1.1
if [[ $1 == "" ]]; then
  echo "Need host parameter"
  echo "You can try localhost:8545"
  exit
fi

host=$1

# Just some rpc examples using curl
# curl -X POST --data '{"jsonrpc":"2.0","method":"eth_getLogs","params":["0x16"],"id":73}' $host

echo "Chain ID:"
curl -k -H "Content-Type: application/json" -X POST --data '{"jsonrpc":"2.0","method":"eth_chainId","id":73}' $host
echo ""

echo "Block Number:"
curl -k -H "Content-Type: application/json" -X POST --data '{"jsonrpc":"2.0","method":"eth_blockNumber","id":73}' $host
echo ""

echo "Block 10_263_655"
curl -k -H "Content-Type: application/json" -X POST --data '{"jsonrpc":"2.0","method":"eth_getBlockByNumber","params":["0x9c41b7",false],"id":73}' $host
echo ""

# Counts the number of fleet contracts
echo "Total Fleets:"
curl -k -H "Content-Type: application/json" -X POST --data '{"jsonrpc":"2.0","method":"dio_codeCount","params":["0x7e9d94e966d33cff302ef86e2337df8eaf9a6388d45e4744321240599d428343"],"id":73}' $host
echo ""

# Counts all accounts by hash
# 0xe3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855 is the null hash
echo "All Codes:"
curl -k -H "Content-Type: application/json"  -X POST --data '{"jsonrpc":"2.0","method":"dio_codeGroups","params":["0x16"],"id":73}' $host
echo ""

# Counts all balances
echo "Total Balances:"
curl -k -H "Content-Type: application/json"  -X POST --data '{"jsonrpc":"2.0","method":"dio_supply","params":["0x16"],"id":73}' $host
echo ""



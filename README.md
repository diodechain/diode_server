![diode logo](https://diode.io/images/logo-trans.svg)
> ### Secure. Super Light. Web3. 
> An Ethereum Chain Fork for the Web3

[![Build Status](https://travis-ci.com/diodechain/diode_server_ex.svg?branch=master)](https://travis-ci.com/diodechain/diode_server_ex)

# Diode Miner & Traffic Gateway

This server is the main Diode blockchain node. It implements both Diode PEER and EDGE protocols. After startup it will automatically connect to the network, and start mining and start acting as a traffic relay.

Traffic Gateways should always be setup on publicly reachable interfaces with a public IP. If the Node is not reachable from other nodes it might eventually blocked. 

By default it will mine using 75% of one CPU. This number can be controlled or set to 'disabled' using the environment variable `WORKER_MODE`

Alternative it can be specified using an additional config file in config/diode.exs:

```Elixir
use Mix.Config

System.put_env("WORKER_MODE", "50")
# System.put_env("WORKER_MODE", "disabled")
```

# Pre-Requisites

* Elixir 1.10.4
* make & autoconf & libtool-bin & gcc & g++ & boost
* daemontools

# Building

```bash
mix deps.get
mix compile
```

# Running tests

```bash
make test
```

# Using for smart contract development

The diode server can be used as RPC server for Smart Contract development. To start a local network similiar to _ganache_ there is a predefined shell script. Just run:

```
./dev
```

And a dedicated local rpc server start-up

# Running

The initial syncing of the network will take multiple hours. So it's advised to start directly with a superviser such as from the daemontools. To start with that
on macOS or linux run:

```
supervise .
```

# Diferences from main Ethereuem (geth)

- Block Header: We added the Miner Signature for BlockQuick
- No ommers
- EVM
  - 100% Constantinople instruction set
  - blockhash() limit has been extended from the 256 previous blocks to previous 131072 blocks instead 
- Protocols
  - Node-to-Node Protocol (PEER) has been *replaced* to implement Gateway functionality
  - Node-to-Edge Protocol (EDGE) has been *added* for communication with IoT devices, desktop, mobile and other nano client applications.
- RPC
  - Mostly compatible (please report issues when you find a difference to the official Ethereum RPC)
  - Added Diode Commands 
    - dio_getObject (object_key)
      
      Fetches one object such as device information from the Kademlia-Network

    - dio_getNode (node_key)

      Fetches information about the specified node when existing.

    - dio_getPool

      Returns the current transaction pool.

    - dio_codeCount* (hash)

      Returns the number of accounts that have a matching code hash. This is usefull to count the deployments of a certain contract.

    - dio_codeGroups*

      Returns code hashes and counts of all deployed contracts. (Likely to be removed)

    - dio_supply

      Returns the existing supply of DIO in the network.

    - dio_network

      Returns the network of connected Miners known to the current node.

    - dio_accounts*

      Returns a list of known accounts.
   
    Those commands with a * will likely be removed or changed when the network has grown beyond certain bounds making these calls harder to scale.
# Running Your Miner

At the time of writing (24th January 2022) the Diode main chain is roughly 50gb of raw data. There are two primary ways of syncing that data:

1) Full validation sync (will take around a month)
2) Download the first 3.000.000 pre-validated blocks and sync only the rest (1-2 days)

## Full Validation Startup

1. git checkout `https://github.com/diodechain/diode_server.git`
1. Start the miner with `./run` or `./docker` if you want to wrap the execution in a docker container.

Dockerization will allow to run it in background and restart it when it crashes. While you can get the same restart behaviour with `./run` when using the [daemontools](https://cr.yp.to/daemontools.html)

## Download pre-validated blocks

This dataset contains the first 3 million validated blocks and will speed up your initial sync a lot:

1. Download the pre-validated file `wget http://eu2.prenet.diode.io:8000/blockchain.sq3.xz`
1. Check the md5-checksum to be `f5285a5827611e159073985ebefc47d2`
1. Move the file to `data_prod/blockchain.sq3.xz`
1. Extract the file using xz `xz -d blockchain.sq3.xz`

## Managing Stake

If you already have dio balance on your miners wallet you can add that to your stake from the Miners Shell.

### Checking your current Balance / Stake

* Print your address
    ```elixir
    iex> Wallet.printable(Diode.miner)
    "riot_silly       (0xd02ab46443c1dcdcd680f253d436a98d95f22dd1)"
    ```
* Check your balance
    ```elixir
    iex> Shell.get_balance(Diode.miner)
    0
    ```
* Check your current stake
    ```elixir
    iex> Shell.get_miner_stake(Diode.miner)
    0
    ```

You can also use the blockchain explorer at https://diode.io/prenet to check your balance after finding your address using `Wallet.printable(Diode.miner)`. The direct link would include the address you want to check: https://diode.io/prenet/#/address/0xd02ab46443c1dcdcd680f253d436a98d95f22dd1


### Converting Balance to Stake

Converting Balance to Stake is a procedure with a built-in time-lock to prevent hit-and-run attacks against the network. Staking any balance will keep your funds locked for ~30 days before they are finally staked. Keep this in mind.

To test if the transaction would work to stake 5 io:

```elixir
Shell.call_from(Diode.miner, Diode.registry_address, "MinerStake", [], [], value: Shell.ether(5))
```

To submit the transaction to stake 5 dio:

```elixir
Shell.submit_from(Diode.miner, Diode.registry_address, "MinerStake", [], [], value: Shell.ether(5))
```

To convert stake back to 5 dio balance. First you need to unstake the amount and wait for the time-lock to expire:

```elixir
Shell.submit_from(Diode.miner, Diode.registry_address, "MinerUnstake", [:uint256], [Shell.ether(5)])
```

After the time-lock has expired, you can withdraw the amount to balance. The node explorer at https://diode.io/prenet/#/address/__(0x your node_address)__ will show the amount as `Withdrawable` once available for withdrawing.

```elixir
Shell.submit_from(Diode.miner, Diode.registry_address, "MinerWithdraw")
```

### Flushing the transaction pool

All transactions that are received as "to be processed" are stored in the transaction pool. This pool can be flushed, if for example too many future nonce transactions (`nonce too high`) occur.

To flush the pool:

```
Chain.Pool.flush()
```

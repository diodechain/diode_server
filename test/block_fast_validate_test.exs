# Diode Server
# Copyright 2021-2024 Diode
# Licensed under the Diode License, Version 1.1
defmodule BlockFastValidateTest do
  use ExUnit.Case, async: false

  alias Chain.Block

  setup_all do
    TestHelper.reset()
    :ok
  end

  defp candidate_block do
    Chain.Worker.with_candidate(fn block -> block end)
  end

  test "simulate/2 with fast validation does not assign transaction_hash" do
    wire = candidate_block()
    assert is_binary(Block.txhash(wire))

    sim = Block.simulate(wire, true)
    assert sim.header.transaction_hash == nil
  end

  test "validate/2 fast preserves wire header fields used by EdgeV2" do
    wire = candidate_block()
    tx_hash = Block.txhash(wire)
    block_hash = Block.hash(wire)
    miner_signature = wire.header.miner_signature
    nonce = wire.header.nonce

    assert is_binary(tx_hash)
    assert is_binary(block_hash)
    assert is_binary(miner_signature)

    assert %Block{} = stored = Block.validate(wire, true)

    assert Block.txhash(stored) == tx_hash
    assert Block.hash(stored) == block_hash
    assert stored.header.miner_signature == miner_signature
    assert stored.header.nonce == nonce

    cached =
      BlockProcess.with_block(block_hash, fn block ->
        block
      end)

    assert Block.txhash(cached) == tx_hash
    assert cached.header.miner_signature == miner_signature
  end

  test "BlockProcess.with_block repairs a stale cached header on load" do
    wire = candidate_block()
    assert %Block{} = block = Block.validate(wire, true)

    hash = Block.hash(block)
    tx_hash = Block.txhash(block)

    corrupt = put_in(block.header.transaction_hash, nil)
    EtsLru.put(BlockProcess, hash, Block.strip_state(corrupt))

    assert Block.txhash(
             BlockProcess.with_block(hash, fn cached ->
               cached
             end)
           ) == tx_hash
  end

  test "repair_transaction_hash backfills on load and persists to disk" do
    wire = candidate_block()
    assert %Block{} = block = Block.validate(wire, true)

    hash = Block.hash(block)
    tx_hash = Block.txhash(block)

    corrupt = put_in(block.header.transaction_hash, nil)
    Model.ChainSql.repair_block_data(corrupt)
    EtsLru.flush(BlockProcess)

    assert Model.Sql.lookup!(Model.ChainSql, "SELECT data FROM blocks WHERE hash = ?1", hash)
           |> BertInt.decode!()
           |> Block.txhash() == nil

    loaded = BlockProcess.with_block(hash, fn cached -> cached end)
    assert Block.txhash(loaded) == tx_hash

    assert Model.Sql.lookup!(Model.ChainSql, "SELECT data FROM blocks WHERE hash = ?1", hash)
           |> BertInt.decode!()
           |> Block.txhash() == tx_hash
  end
end

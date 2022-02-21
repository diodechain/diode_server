# Diode Server
# Copyright 2021 Diode
# Licensed under the Diode License, Version 1.1
defmodule Chain.GenesisFactory do
  alias Chain.Account, as: Account

  @spec testnet() :: Chain.Block.t()
  def testnet() do
    genesis(genesis_accounts(), genesis_transactions(genesis_miner()), genesis_miner())
  end

  def testnet_parent() do
    genesis_parent(genesis_state(genesis_accounts()), genesis_miner())
  end

  def genesis_state(accounts) do
    Enum.reduce(accounts, Chain.State.new(), fn {address, user_account}, state ->
      Chain.State.set_account(state, address, user_account)
    end)
  end

  @spec genesis_accounts() :: [{binary(), Account.t()}]
  def genesis_accounts() do
    ChainDefinition.genesis_accounts()
  end

  @spec genesis_miner :: Wallet.t()
  def genesis_miner() do
    ChainDefinition.genesis_miner()
  end

  @spec genesis_timestamp() :: non_neg_integer()
  def genesis_timestamp() do
    ChainDefinition.genesis_timestamp()
  end

  @spec genesis_transactions(Wallet.t()) :: [Chain.Transaction.t(), ...]
  def genesis_transactions(miner) do
    ChainDefinition.genesis_transactions(miner)
  end

  @spec genesis_parent(Chain.State.t(), Wallet.t()) :: Chain.Block.t()
  def genesis_parent(state, miner) do
    %Chain.Block{
      header: %Chain.Header{
        number: -1,
        block_hash: ChainDefinition.genesis_pre_hash(),
        state_hash: state
      },
      coinbase: miner
    }
  end

  @spec genesis(any(), [Chain.Transaction.t()], Wallet.t()) :: Chain.Block.t()
  def genesis(accounts, transactions, miner) do
    state = genesis_state(accounts)
    parent = genesis_parent(state, miner)
    block = Chain.Block.create(parent, transactions, miner, genesis_timestamp())
    header = Chain.Block.header(block)

    header =
      %{header | miner_signature: <<0::520>>}
      |> Chain.Header.update_hash()

    %{block | header: header}
  end
end

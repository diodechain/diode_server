# Diode Server
# Copyright 2020 IoT Blockchain Technology Corporation LLC (IBTC)
# Licensed under the Diode License, Version 1.0
defmodule ChainDefinition.Stagenet do
  alias ChainDefinition.Voyager
  @voyager 10

  @spec network(any) :: ChainDefinition.t()
  def network(blockheight) when blockheight < @voyager do
    %ChainDefinition{
      block_reward_position: :first,
      chain_id: 41042,
      check_window: false,
      get_block_hash_limit: 131_072,
      min_diversity: 0,
      min_transaction_fee: false
    }
  end

  def network(blockheight) when blockheight >= @voyager do
    %ChainDefinition{
      network(blockheight - 1)
      | block_reward_position: :last,
        min_transaction_fee: true,
        chain_id: 13
    }
  end

  def hardforks(block) do
    if Chain.Block.number(block) == @voyager - 1 do
      state = Voyager.apply(Chain.Block.state(block))
      Chain.Block.with_state(block, state)
    else
      block
    end
  end

  @spec genesis_accounts() :: [{binary(), Account.t()}]
  def genesis_accounts() do
    File.read!("data/genesis.bin") |> Chain.State.from_binary() |> Chain.State.accounts()
  end

  @spec genesis_transactions(Wallet.t()) :: [Chain.Transaction.t()]
  def genesis_transactions(_miner) do
    []
  end

  @spec genesis_pre_hash :: <<_::256>>
  def genesis_pre_hash() do
    "0Z0Z0Z0Z0Z0Z0Z0Z0Z0Z0Z0Z0Z0Z0Z0Z"
  end

  @spec genesis_miner :: Wallet.t()
  def genesis_miner() do
    Wallet.from_privkey(
      <<149, 210, 74, 221, 235, 25, 240, 87, 85, 95, 119, 147, 106, 182, 149, 28, 112, 227, 22,
        173, 235, 134, 113, 172, 125, 222, 191, 154, 120, 128, 129, 203>>
    )
  end

  @spec genesis_timestamp :: non_neg_integer()
  def genesis_timestamp() do
    1_597_154_008
  end
end

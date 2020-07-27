# Diode Server
# Copyright 2020 IoT Blockchain Technology Corporation LLC (IBTC)
# Licensed under the Diode License, Version 1.0
defmodule ChainDefinition.Mainnet do
  alias ChainDefinition.Voyager

  # Planned date Monday 31st August
  @voyager 713_277
  @spec network(any) :: ChainDefinition.t()
  def network(blockheight) when blockheight >= @voyager do
    %ChainDefinition{
      check_window: true,
      get_block_hash_limit: 131_072,
      min_diversity: 1,
      # changed:
      block_reward_position: :last,
      chain_id: 15,
      min_transaction_fee: true
    }
  end

  def network(blockheight) when blockheight >= 360_000 do
    %ChainDefinition{
      block_reward_position: :first,
      chain_id: 41043,
      check_window: true,
      min_diversity: 1,
      min_transaction_fee: false,
      # changed:
      get_block_hash_limit: 131_072
    }
  end

  def network(blockheight) when blockheight >= 11_000 do
    %ChainDefinition{
      block_reward_position: :first,
      chain_id: 41043,
      check_window: true,
      get_block_hash_limit: 256,
      min_transaction_fee: false,
      # changed:
      min_diversity: 1
    }
  end

  def network(blockheight) when blockheight < 11_000 do
    %ChainDefinition{
      get_block_hash_limit: 256,
      min_transaction_fee: false,
      block_reward_position: :first,
      check_window: true,
      chain_id: 41043,
      min_diversity: 0
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
    1_579_779_937
  end
end

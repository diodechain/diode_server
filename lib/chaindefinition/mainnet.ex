# Diode Server
# Copyright 2021-2024 Diode
# Licensed under the Diode License, Version 1.1
defmodule ChainDefinition.Mainnet do
  alias ChainDefinition.Ulysses
  alias ChainDefinition.{Ulysses, Voyager, Pioneer}

  # Planned date Monday 31st August 2020
  @voyager 713_277
  @voyager_t1 @voyager - 1
  # Planned date Monday 10 January 2021
  @pioneer 1_264_615
  @pioneer_t1 @pioneer - 1
  # Planned date Friday 26 June 2021
  @new_horizons 2_034_446
  # Planned 15.07.2024
  @ulysses 7_573_047
  @ulysses_t1 @ulysses - 1

  @spec network(any) :: ChainDefinition.t()
  def network(blockheight) when blockheight >= @new_horizons do
    %ChainDefinition{
      check_window: true,
      get_block_hash_limit: 131_072,
      min_diversity: 1,
      block_reward_position: :last,
      chain_id: 15,
      min_transaction_fee: true,
      # changed:
      allow_contract_override: false
    }
  end

  def network(blockheight) when blockheight >= @voyager do
    %ChainDefinition{
      check_window: true,
      get_block_hash_limit: 131_072,
      min_diversity: 1,
      allow_contract_override: true,
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
      allow_contract_override: true,
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
      allow_contract_override: true,
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
      min_diversity: 0,
      allow_contract_override: true
    }
  end

  def hardforks(block) do
    case Chain.Block.number(block) do
      @ulysses_t1 ->
        state = Ulysses.apply(Chain.Block.state(block))
        Chain.Block.ensure_state(block, state)

      @voyager_t1 ->
        state = Voyager.apply(Chain.Block.state(block))
        Chain.Block.ensure_state(block, state)

      @pioneer_t1 ->
        state = Pioneer.apply(Chain.Block.state(block))
        Chain.Block.ensure_state(block, state)

      _ ->
        block
    end
  end

  @spec genesis_accounts() :: [{binary(), Chain.Account.t()}]
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

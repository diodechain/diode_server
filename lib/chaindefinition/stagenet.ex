# Diode Server
# Copyright 2020 Diode (IBTC)
# Licensed under the Diode License, Version 1.1
defmodule ChainDefinition.Stagenet do
  alias ChainDefinition.{Voyager, Pioneer}
  @voyager 10
  @voyager_t1 @voyager - 1
  @pioneer 20
  @pioneer_t1 @pioneer - 1
  @new_horizons 20

  @spec network(any) :: ChainDefinition.t()
  def network(blockheight) when blockheight < @voyager do
    %ChainDefinition{
      block_reward_position: :first,
      chain_id: 41042,
      check_window: false,
      get_block_hash_limit: 131_072,
      min_diversity: 0,
      min_transaction_fee: false,
      allow_contract_override: true
    }
  end

  def network(blockheight) when blockheight >= @voyager do
    %ChainDefinition{
      network(@voyager - 1)
      | block_reward_position: :last,
        min_transaction_fee: true,
        chain_id: 13
    }
  end

  def network(blockheight) when blockheight >= @new_horizons do
    %ChainDefinition{
      network(@new_horizons - 1)
      | allow_contract_override: false
    }
  end

  def hardforks(block) do
    case Chain.Block.number(block) do
      @voyager_t1 ->
        state = Voyager.apply(Chain.Block.state(block))
        Chain.Block.with_state(block, state)

      @pioneer_t1 ->
        state = Pioneer.apply(Chain.Block.state(block))
        Chain.Block.with_state(block, state)

      _ ->
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

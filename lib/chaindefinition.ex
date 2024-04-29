# Diode Server
# Copyright 2021-2024 Diode
# Licensed under the Diode License, Version 1.1
defmodule ChainDefinition do
  @enforce_keys [
    :block_reward_position,
    :chain_id,
    :check_window,
    :min_diversity,
    :min_transaction_fee,
    :get_block_hash_limit,
    :allow_contract_override
  ]
  defstruct @enforce_keys

  @type t :: %ChainDefinition{
          block_reward_position: :last | :first,
          chain_id: non_neg_integer(),
          check_window: boolean(),
          get_block_hash_limit: non_neg_integer(),
          min_diversity: non_neg_integer(),
          min_transaction_fee: boolean(),
          allow_contract_override: boolean()
        }

  @spec get_block_hash_limit(non_neg_integer) :: non_neg_integer()
  def get_block_hash_limit(blockheight) do
    chain_definition(blockheight).get_block_hash_limit
  end

  @spec min_diversity(non_neg_integer) :: non_neg_integer()
  def min_diversity(blockheight) do
    chain_definition(blockheight).min_diversity
  end

  @spec block_reward_position(non_neg_integer) :: :last | :first
  def block_reward_position(blockheight) do
    chain_definition(blockheight).block_reward_position
  end

  @spec min_transaction_fee(non_neg_integer) :: boolean()
  def min_transaction_fee(blockheight) do
    chain_definition(blockheight).min_transaction_fee
  end

  @spec allow_contract_override(non_neg_integer) :: boolean()
  def allow_contract_override(blockheight) do
    chain_definition(blockheight).allow_contract_override
  end

  @spec chain_id(non_neg_integer) :: non_neg_integer()
  def chain_id(blockheight) do
    chain_definition(blockheight).chain_id
  end

  @spec check_window(non_neg_integer) :: boolean()
  def check_window(blockheight) do
    chain_definition(blockheight).check_window
  end

  @spec genesis_accounts() :: [{binary(), Chain.Account.t()}]
  def genesis_accounts() do
    chain_definition().genesis_accounts()
  end

  @spec genesis_transactions(Wallet.t()) :: [Chain.Transaction.t()]
  def genesis_transactions(miner) do
    chain_definition().genesis_transactions(miner)
  end

  @spec genesis_timestamp :: non_neg_integer()
  def genesis_timestamp() do
    chain_definition().genesis_timestamp()
  end

  @spec genesis_miner :: Wallet.t()
  def genesis_miner() do
    chain_definition().genesis_miner()
  end

  defp chain_definition() do
    :persistent_term.get(:chain_definition, nil)
  end

  @spec chain_definition(non_neg_integer()) :: ChainDefinition
  defp chain_definition(blockheight) do
    chain_definition().network(blockheight)
  end

  @spec genesis_pre_hash :: <<_::256>>
  def genesis_pre_hash() do
    chain_definition().genesis_pre_hash()
  end

  @spec hardforks(Chain.Block.t()) :: Chain.Block.t()
  def hardforks(sim_block) do
    chain_definition().hardforks(sim_block)
  end
end

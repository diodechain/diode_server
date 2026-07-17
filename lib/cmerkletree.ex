# Diode Server
# Copyright 2021-2024 Diode
# Licensed under the Diode License, Version 1.1
defmodule CMerkleTree do
  @on_load :load_nifs

  def load_nifs do
    :erlang.load_nif(~c"./priv/merkletree_nif", 0)
  end

  def count_zeros(binary) when is_binary(binary), do: count_zeros_raw(binary)
  defp count_zeros_raw(_binary), do: error()

  @doc """
  Returns `{locked_states_count, pending_orphan_count, shared_states_live, merkletree_resources}`.
  """
  def nif_stats, do: nif_stats_raw()
  defp nif_stats_raw, do: error()

  def account_map_new(), do: error()
  def account_map_clone(_map), do: error()
  def account_map_root_hash(_map), do: error()
  def account_map_state_roots(_map), do: error()
  def account_map_proof(_map, _addr), do: error()
  def account_map_proof(_map, _addr, _key), do: error()
  def account_map_lock(_map), do: error()
  def account_map_get(_map, _addr), do: error()
  def account_map_put(_map, _addr, _nonce, _balance, _storage, _code), do: error()
  def account_map_delete(_map, _addr), do: error()
  def account_map_size(_map), do: error()
  def account_map_to_list(_map), do: error()
  def account_map_difference_full(_map_a, _map_b), do: error()
  def account_map_apply_difference(_map, _delta), do: error()
  def account_map_compact(_map), do: error()
  def account_map_uncompact_state(_map), do: error()
  def account_map_storage_put_map(_map, _updates), do: error()
  def account_map_storage(_map, _addr, _spec), do: error()
  def account_map_storage_roots(_map, _addr), do: error()

  defp error, do: :erlang.nif_error(:nif_not_loaded)
end

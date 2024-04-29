# Diode Server
# Copyright 2021-2024 Diode
# Licensed under the Diode License, Version 1.1
defmodule MapMerkleTree do
  # ========================================================
  # Public Functions only in the facade
  # ========================================================
  def new() do
    {MapMerkleTree, %{}, %{}}
  end

  def from_map(%{} = map) do
    {MapMerkleTree, %{}, map}
  end

  # ========================================================
  # Wrapper functions for the impls
  # ========================================================
  def compact(tree) do
    tree
  end

  def merkle(tree) do
    MerkleTree.copy(tree, MerkleTree2)
  end

  def root_hash(tree) do
    MerkleTree.root_hash(merkle(tree))
  end

  def root_hashes(tree) do
    MerkleTree.root_hashes(merkle(tree))
  end

  def get_proofs(tree, key) do
    MerkleTree.get_proofs(merkle(tree), key)
  end

  def get({MapMerkleTree, _opts, dict}, key) do
    Map.get(dict, key)
  end

  def size({MapMerkleTree, _opts, dict}) do
    map_size(dict)
  end

  def bucket_count(tree) do
    MerkleTree.bucket_count(merkle(tree))
  end

  def to_list({MapMerkleTree, _opts, dict}) do
    Map.to_list(dict)
  end

  def delete({MapMerkleTree, opts, dict}, key) do
    {MapMerkleTree, opts, Map.delete(dict, key)}
  end

  def member?({MapMerkleTree, _opts, dict}, key) do
    Map.has_key?(dict, key)
  end

  def insert_items({MapMerkleTree, opts, dict}, items) do
    dict =
      Enum.reduce(items, dict, fn {key, value}, dict ->
        if null?(value) do
          Map.delete(dict, key)
        else
          Map.put(dict, key, value)
        end
      end)

    {MapMerkleTree, opts, dict}
  end

  defp null?(nil) do
    true
  end

  defp null?(binary) when is_binary(binary) do
    binary == <<0::unsigned-size(256)>>
  end

  defp null?(int) when is_integer(int) do
    null?(<<int::unsigned-size(256)>>)
  end
end

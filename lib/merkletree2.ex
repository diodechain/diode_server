# Diode Server
# Copyright 2021 Diode
# Licensed under the Diode License, Version 1.1
defmodule MerkleTree2 do
  @type key_type :: binary() | integer()
  @type value_type :: term()

  @type item :: {key_type(), value_type()}
  @type hash_type :: <<_::256>>

  @type proof_type :: {proof_type, proof_type} | [any()]
  @type merkle :: {atom(), map(), any()}

  # ========================================================
  # Public Functions only in the facade
  # ========================================================
  def new() do
    {__MODULE__, %{}, {HeapMerkleTree.new(), MapMerkleTree.new()}}
  end

  # ========================================================
  # Wrapper functions for the impls
  # ========================================================
  @spec compact(merkle()) :: merkle()
  def compact({__MODULE__, %{}, {_heaptree, maptree}}) do
    maptree
  end

  @spec merkle(merkle()) :: merkle()
  def merkle(merkle) do
    merkle
  end

  defp maptree({__MODULE__, %{}, {_heaptree, maptree}}), do: maptree
  defp heaptree({__MODULE__, %{}, {heaptree, _maptree}}), do: heaptree

  @spec root_hash(merkle()) :: hash_type()
  def root_hash(merkle) do
    HeapMerkleTree.root_hash(heaptree(merkle))
  end

  @spec root_hashes(merkle()) :: [hash_type()]
  def root_hashes(merkle) do
    HeapMerkleTree.root_hashes(heaptree(merkle))
  end

  @spec get_proofs(merkle(), key_type()) :: proof_type()
  def get_proofs(merkle, key) do
    HeapMerkleTree.get_proofs(heaptree(merkle), key)
  end

  @spec get(merkle(), key_type()) :: value_type()
  def get(merkle, key) do
    MapMerkleTree.get(maptree(merkle), key)
  end

  @spec size(merkle()) :: non_neg_integer()
  def size(merkle) do
    MapMerkleTree.size(maptree(merkle))
  end

  @spec bucket_count(merkle()) :: pos_integer()
  def bucket_count(merkle) do
    HeapMerkleTree.bucket_count(heaptree(merkle))
  end

  @spec to_list(merkle()) :: [item()]
  def to_list(merkle) do
    MapMerkleTree.to_list(maptree(merkle))
  end

  @spec delete(merkle(), key_type()) :: merkle()
  def delete({__MODULE__, %{}, {heaptree, maptree}}, key) do
    if MapMerkleTree.member?(maptree, key) do
      heaptree = HeapMerkleTree.delete(heaptree, key)
      maptree = MapMerkleTree.delete(maptree, key)
      {__MODULE__, %{}, {heaptree, maptree}}
    else
      {__MODULE__, %{}, {heaptree, maptree}}
    end
  end

  @spec member?(merkle(), key_type()) :: boolean()
  def member?(merkle, key) do
    MapMerkleTree.member?(maptree(merkle), key)
  end

  @spec insert_items(merkle(), [item()]) :: merkle()
  def insert_items({__MODULE__, %{}, {heaptree, maptree}}, items) do
    items = Enum.reject(items, fn {key, value} -> MapMerkleTree.get(maptree, key) == value end)
    heaptree = HeapMerkleTree.insert_items(heaptree, items)
    maptree = MapMerkleTree.insert_items(maptree, items)
    {__MODULE__, %{}, {heaptree, maptree}}
  end
end

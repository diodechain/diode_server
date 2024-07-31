# Diode Server
# Copyright 2021-2024 Diode
# Licensed under the Diode License, Version 1.1
defmodule MerkleTree do
  @type key_type :: binary() | integer()
  @type value_type :: term()

  @type item :: {key_type(), value_type()}
  @type hash_type :: <<_::256>>

  @type proof_type :: {proof_type, proof_type} | [any()]
  @type merkle :: {atom(), map(), any()}
  @type t :: {atom(), map(), any()}

  # ========================================================
  # Public Functions only in the facade
  # ========================================================
  def new() do
    MerkleTree2.new()
  end

  def copy({mod, _opts, _tree} = merkle) do
    copy(merkle, mod)
  end

  def copy(merkle = {mod, _, _}, mod) do
    merkle
  end

  def copy(merkle, mod) do
    insert_items(mod.new(), to_list(merkle))
  end

  def difference(a, b) do
    a = to_list(a) |> Map.new()
    b = to_list(b) |> Map.new()
    keys = MapSet.union(MapSet.new(Map.keys(a)), MapSet.new(Map.keys(b)))

    Enum.reduce(keys, %{}, fn key, set ->
      a_value = Map.get(a, key)
      b_value = Map.get(b, key)

      if a_value != b_value do
        Map.put(set, key, {a_value, b_value})
      else
        set
      end
    end)
  end

  @spec insert(merkle(), key_type(), value_type()) :: merkle()
  def insert(merkle, key, value) do
    insert_items(merkle, [{key, value}])
  end

  @spec insert_item(merkle(), item()) :: merkle()
  def insert_item(merkle, item) do
    insert_items(merkle, [item])
  end

  # ========================================================
  # Wrapper functions for the impls
  # ========================================================
  @spec compact(merkle()) :: merkle()
  def compact({mod, _opts, _tree} = merkle) do
    mod.compact(merkle)
  end

  @spec merkle(merkle()) :: merkle()
  def merkle({mod, _opts, _tree} = merkle) do
    mod.merkle(merkle)
  end

  @spec root_hash(merkle()) :: hash_type()
  def root_hash({mod, _opts, _tree} = merkle) do
    mod.root_hash(merkle)
  end

  @spec root_hashes(merkle()) :: [hash_type()]
  def root_hashes({mod, _opts, _tree} = merkle) do
    mod.root_hashes(merkle)
  end

  @spec get_proofs(merkle(), key_type()) :: proof_type()
  def get_proofs({mod, _options, _tree} = merkle, key) do
    mod.get_proofs(merkle, key)
  end

  @spec get(merkle(), key_type()) :: value_type()
  def get({mod, _options, _tree} = merkle, key) do
    mod.get(merkle, key)
  end

  @spec size(merkle()) :: non_neg_integer()
  def size({mod, _options, _tree} = merkle) do
    mod.size(merkle)
  end

  @spec bucket_count(merkle()) :: pos_integer()
  def bucket_count({mod, _options, _tree} = merkle) do
    mod.bucket_count(merkle)
  end

  @spec to_list(merkle()) :: [item()]
  def to_list({mod, _options, _tree} = merkle) do
    mod.to_list(merkle)
  end

  @spec delete(merkle(), key_type()) :: merkle()
  def delete({mod, _options, _tree} = merkle, key) do
    mod.delete(merkle, key)
  end

  @spec member?(merkle(), key_type()) :: boolean()
  def member?({mod, _opts, _tree} = merkle, key) do
    mod.member?(merkle, key)
  end

  @spec insert_items(merkle(), Enumerable.t()) :: merkle()
  def insert_items({mod, _options, _tree} = merkle, items) do
    mod.insert_items(merkle, items)
  end
end

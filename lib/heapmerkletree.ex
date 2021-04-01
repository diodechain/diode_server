# Diode Server
# Copyright 2021 Diode
# Licensed under the Diode License, Version 1.1
defmodule HeapMerkleTree do
  @type key_type :: binary() | integer()
  @type value_type :: term()

  @type item :: {key_type(), value_type()}
  @type hash_type :: <<_::256>>

  @type proof_type :: {proof_type, proof_type} | [any()]

  @type hash_count :: {[binary()], non_neg_integer()}
  @type tree_leaf :: {:leaf, hash_count() | nil, binary(), map()}
  @type tree_node :: {:node, hash_count() | nil, binary(), tree(), tree()}
  @type tree :: tree_leaf() | tree_node()
  @type merkle :: {__MODULE__, map(), tree() | nil}

  @spec new() :: merkle()
  def new() do
    tree = update_merkle_hash_count({:leaf, nil, "", %{}})
    {__MODULE__, %{}, tree}
  end

  @spec root_hash(merkle()) :: hash_type()
  def root_hash(merkle) do
    root_hashes(merkle)
    |> signature()
  end

  @spec root_hashes(merkle()) :: [hash_type()]
  def root_hashes({__MODULE__, _options, tree}) do
    update_merkle_hash_count(tree)
    |> merkle_hashes()
  end

  @spec get_proofs(merkle(), key_type()) :: proof_type()
  def get_proofs({__MODULE__, _options, tree}, key) do
    bkey = to_binary(key)
    do_get_proofs(tree, bkey, hash(bkey))
  end

  @spec get(merkle(), key_type()) :: value_type()
  def get({__MODULE__, _options, tree}, key) do
    bkey = to_binary(key)
    do_get(tree, bkey, hash(bkey))
  end

  @spec size(merkle()) :: non_neg_integer()
  def size({__MODULE__, _options, tree}) do
    do_size(tree)
  end

  @spec bucket_count(merkle()) :: pos_integer()
  def bucket_count({__MODULE__, _options, tree}) do
    do_bucket_count(tree)
  end

  @spec to_list(merkle()) :: [item()]
  def to_list({__MODULE__, _options, tree}) do
    do_to_list(tree)
  end

  @spec delete(merkle(), key_type()) :: merkle()
  def delete({__MODULE__, options, tree}, key) do
    bkey = to_binary(key)

    tree =
      update_bucket(tree, hash(bkey), fn {:leaf, _hash_count, prefix, bucket} ->
        {:leaf, nil, prefix, Map.delete(bucket, bkey)}
      end)
      |> update_merkle_hash_count()

    {__MODULE__, options, tree}
  end

  @spec member?(merkle(), key_type()) :: boolean()
  def member?(tree, key) do
    nil != get(tree, key)
  end

  @spec insert(merkle(), key_type(), value_type()) :: merkle()
  def insert(tree, key, value) do
    insert_items(tree, [{key, value}])
  end

  @spec insert_item(merkle(), item()) :: merkle()
  def insert_item(tree, item) do
    insert_items(tree, [item])
  end

  @spec insert_items(merkle(), [item()]) :: merkle()
  def insert_items({__MODULE__, options, tree}, items) do
    tree =
      Enum.reduce(items, tree, fn {key, value}, acc ->
        bkey = to_binary(key)

        update_bucket(acc, hash(bkey), fn {:leaf, _hash_count, prefix, bucket} ->
          bucket =
            case to_binary(value) do
              <<0::unsigned-size(256)>> -> Map.delete(bucket, bkey)
              value -> Map.put(bucket, bkey, value)
            end

          {:leaf, nil, prefix, bucket}
        end)
      end)
      |> update_merkle_hash_count()

    {__MODULE__, options, tree}
  end

  # ========================================================
  # Internal
  # ========================================================
  @leaf_size 16
  @left <<0::size(1)>>
  @right <<1::size(1)>>

  @spec do_get(tree(), binary(), binary()) :: any()
  defp do_get({:node, _hash_count, prefix, left, right}, key, hash) do
    case decide(hash, prefix) do
      true -> do_get(left, key, hash)
      false -> do_get(right, key, hash)
    end
  end

  defp do_get({:leaf, _hash_count, _prefix, bucket}, key, _hash) do
    Map.get(bucket, key)
  end

  @spec do_get_proofs(tree(), binary(), binary()) :: any()
  defp do_get_proofs({:node, _hash_count, prefix, left, right}, key, hash) do
    case decide(hash, prefix) do
      true -> {do_get_proofs(left, key, hash), merkle_hash(right, hash)}
      false -> {merkle_hash(left, hash), do_get_proofs(right, key, hash)}
    end
  end

  defp do_get_proofs({:leaf, _hash_count, prefix, bucket}, key, _hash) do
    bucket_to_leaf(bucket, prefix, key)
  end

  defp do_size({:leaf, _hash_count, _prefix, bucket}) do
    map_size(bucket)
  end

  defp do_size({:node, _hash_count, _prefix, left, right}) do
    do_size(left) + do_size(right)
  end

  defp do_bucket_count({:leaf, _hash_count, _prefix, _bucket}) do
    1
  end

  defp do_bucket_count({:node, _hash_count, _prefix, left, right}) do
    do_bucket_count(left) + do_bucket_count(right)
  end

  defp do_to_list({:leaf, _hash_count, _prefix, bucket}) do
    Map.to_list(bucket)
  end

  defp do_to_list({:node, _hash_count, _prefix, left, right}) do
    do_to_list(left) ++ do_to_list(right)
  end

  defp hash(value) when is_binary(value) do
    Diode.hash(value)
  end

  @spec key(item()) :: binary()
  defp key({key, _value}) do
    hash(key)
  end

  defp decide(hash, prefix) do
    x = bit_size(prefix)

    case hash do
      <<^prefix::bitstring-size(x), @left::bitstring, _::bitstring>> ->
        true

      <<^prefix::bitstring-size(x), @right::bitstring, _::bitstring>> ->
        false
    end
  end

  @spec update_bucket(tree(), binary(), fun()) :: tree()
  defp update_bucket({:node, _hash_count, prefix, left, right}, key, fun) do
    case decide(key, prefix) do
      true ->
        {:node, nil, prefix, update_bucket(left, key, fun), right}

      false ->
        {:node, nil, prefix, left, update_bucket(right, key, fun)}
    end
  end

  defp update_bucket({:leaf, _hash_count, prefix, bucket}, _key, fun) do
    fun.({:leaf, nil, prefix, bucket})
  end

  defp merkle_hash_count(tree) do
    :erlang.element(2, tree)
  end

  defp merkle_hashes(tree) do
    {hashes, _count} = merkle_hash_count(tree)
    hashes
  end

  defp merkle_hash(tree, hash) do
    hashes = merkle_hashes(tree)
    Enum.at(hashes, hash_to_leafindex(hash))
  end

  defp hash_to_leafindex(hash) do
    <<lastb::unsigned-size(8)>> = binary_part(hash, byte_size(hash), -1)
    rem(lastb, @leaf_size)
  end

  @spec update_merkle_hash_count(tree()) :: tree()
  defp update_merkle_hash_count({:node, nil, prefix, left, right}) do
    left = update_merkle_hash_count(left)
    {hashesl, countl} = merkle_hash_count(left)

    right = update_merkle_hash_count(right)
    {hashesr, countr} = merkle_hash_count(right)

    count = countl + countr
    # Need to merge
    if count <= @leaf_size do
      items = do_to_list({:node, nil, prefix, left, right})

      {:leaf, nil, prefix, Map.new(items)}
      |> update_merkle_hash_count()
    else
      hashes =
        :lists.zipwith(
          fn hashl, hashr ->
            signature([hashl, hashr])
          end,
          hashesl,
          hashesr
        )

      {:node, {hashes, count}, prefix, left, right}
    end
  end

  defp update_merkle_hash_count({:leaf, nil, prefix, bucket}) do
    count = map_size(bucket)
    # Need to split
    if count > @leaf_size do
      {left, right} = Enum.split_with(bucket, fn item -> decide(key(item), prefix) end)

      {:node, nil, prefix, {:leaf, nil, <<prefix::bitstring, @left::bitstring>>, Map.new(left)},
       {:leaf, nil, <<prefix::bitstring, @right::bitstring>>, Map.new(right)}}
      |> update_merkle_hash_count()
    else
      hashes =
        bucket_to_leafes(bucket, prefix)
        |> Enum.map(&signature/1)

      {:leaf, {hashes, count}, prefix, bucket}
    end
  end

  defp update_merkle_hash_count(tree) do
    tree
  end

  defp bucket_to_leafes(bucket, prefix) do
    l0 =
      Enum.map(1..@leaf_size, fn num ->
        [num - 1, prefix]
      end)

    Enum.reduce(bucket, l0, fn item, list ->
      pos = hash_to_leafindex(key(item))
      value = [item | Enum.at(list, pos)]
      List.replace_at(list, pos, value)
    end)
    |> Enum.map(&Enum.reverse/1)
  end

  defp bucket_to_leaf(bucket, prefix, key) do
    pos = hash_to_leafindex(hash(key))
    l0 = [pos, prefix]

    Enum.reduce(bucket, l0, fn item, list ->
      if hash_to_leafindex(key(item)) == pos do
        [item | list]
      else
        list
      end
    end)
    |> Enum.reverse()
  end

  defp signature(list) when is_list(list) do
    hash(BertExt.encode!(list))
  end

  defp to_binary(binary) when is_binary(binary) do
    binary
  end

  defp to_binary(int) when is_integer(int) do
    <<int::unsigned-size(256)>>
  end
end

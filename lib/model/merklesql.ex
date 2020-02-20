# Diode Server
# Copyright 2019 IoT Blockchain Technology Corporation LLC (IBTC)
# Licensed under the Diode License, Version 1.0
defmodule Model.MerkleSql do
  alias Model.Sql
  @type key_type :: binary() | integer()
  @type value_type :: term()

  @type item :: {key_type(), value_type()}
  @type hash_type :: <<_::256>>

  @type proof_type :: {proof_type, proof_type} | [any()]

  @type sql_key :: binary()
  @type hash_count :: {[binary()], non_neg_integer()}
  @type tree_leaf :: {:leaf, hash_count() | nil, binary(), map()}
  @type tree_node :: {:node, hash_count() | nil, binary(), tree(), tree()}
  @type tree :: tree_leaf() | tree_node() | sql_key()
  @type merkle :: {__MODULE__, %{}, sql_key() | tree()}

  @spec new() :: merkle()
  def new() do
    store({__MODULE__, %{}, {:leaf, nil, "", %{}}})
  end

  @spec normalize(merkle()) :: merkle()
  def normalize(merkle) do
    {__MODULE__, %{}, normalized_tree(merkle)}
  end

  @spec store(merkle()) :: merkle()
  def store(merkle) do
    tree =
      normalized_tree(merkle)
      |> sql_store()

    {__MODULE__, %{}, tree}
  end

  @doc """
  null() returns the default empty tree for comparison
  """
  def null() do
    {__MODULE__, %{},
     <<67, 138, 144, 64, 93, 170, 135, 101, 57, 8, 44, 208, 186, 246, 205, 218, 163, 191, 136, 15,
       28, 138, 240, 192, 56, 31, 0, 66, 219, 147, 8, 138>>}
  end

  def restore(sql_key) do
    with_transaction(fn db ->
      case Sql.query!(db, "SELECT data FROM mtree WHERE hash = ?1", bind: [sql_key]) do
        [[data: data]] -> {:ok, {__MODULE__, %{}, sql_decode(data)}}
        [] -> {:error, :not_found}
      end
    end)
  end

  @spec root_hash(merkle()) :: hash_type()
  def root_hash(merkle) do
    root_hashes(merkle)
    |> signature()
  end

  @spec root_hashes(merkle()) :: [hash_type()]
  def root_hashes(merkle) do
    with_transaction(fn db -> merkle_hashes(db, normalized_tree(merkle)) end)
  end

  @spec get_proofs(merkle(), key_type()) :: proof_type()
  def get_proofs(merkle, key) do
    bkey = to_binary(key)
    with_transaction(fn db -> do_get_proofs(db, normalized_tree(merkle), bkey, hash(bkey)) end)
  end

  @spec get(merkle(), key_type()) :: value_type()
  def get({__MODULE__, _options, tree}, key) do
    bkey = to_binary(key)
    with_transaction(fn db -> do_get(db, tree, bkey, hash(bkey)) end)
  end

  @spec size(merkle()) :: non_neg_integer()
  def size({__MODULE__, _options, tree}) do
    with_transaction(fn db -> do_size(db, tree) end)
  end

  @spec bucket_count(merkle()) :: pos_integer()
  def bucket_count(merkle) do
    with_transaction(fn db -> do_bucket_count(db, normalized_tree(merkle)) end)
  end

  @spec to_list(merkle()) :: [item()]
  def to_list({__MODULE__, _options, tree}) do
    with_transaction(fn db -> do_to_list(db, tree) end)
  end

  @spec delete(merkle(), key_type()) :: merkle()
  def delete({__MODULE__, options, tree}, key) do
    bkey = to_binary(key)

    tree =
      with_transaction(fn db ->
        update_bucket(db, tree, hash(bkey), fn {:leaf, _hash_count, prefix, bucket} ->
          {:leaf, nil, prefix, Map.delete(bucket, bkey)}
        end)
      end)

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
      with_transaction(fn db ->
        Enum.reduce(items, tree, fn {key, value}, acc ->
          bkey = to_binary(key)

          update_bucket(db, acc, hash(bkey), fn {:leaf, _hash_count, prefix, bucket} ->
            bucket =
              case to_binary(value) do
                <<0::unsigned-size(256)>> -> Map.delete(bucket, bkey)
                value -> Map.put(bucket, bkey, value)
              end

            {:leaf, nil, prefix, bucket}
          end)
        end)
      end)

    {__MODULE__, options, tree}
  end

  # ========================================================
  # Internal SQL Specific
  # ========================================================
  def init() do
    {:ok, _ret} =
      Sql.query(__MODULE__, """
          CREATE TABLE IF NOT EXISTS mtree (
            hash BLOB PRIMARY KEY,
            data BLOB
          )
      """)

    __MODULE__.new()
  end

  defp with_transaction(fun) do
    fun.(__MODULE__)
  end

  defp normalized_tree({__MODULE__, _options, tree}) do
    with_transaction(fn db -> update_merkle_hash_count(db, tree) end)
  end

  defp sql_key(db, tree) do
    signature(merkle_hashes(db, tree))
  end

  defp sql_store(sql_key) when is_binary(sql_key) do
    sql_key
  end

  # sql_store does the actual mnesia_storage
  defp sql_store(tree) when is_tuple(tree) do
    with_transaction(fn db ->
      tree = update_merkle_hash_count(db, tree)
      do_sql_store(db, tree)
    end)
  end

  defp sql_exists(db, sql_key) do
    case Sql.query(db, "SELECT hash FROM mtree WHERE hash = ?1", bind: [sql_key]) do
      {:ok, []} -> false
      {:ok, [[hash: ^sql_key]]} -> true
    end
  end

  defp do_sql_store(_db, sql_key) when is_binary(sql_key) do
    sql_key
  end

  defp do_sql_store(db, tree) do
    sql_key = sql_key(db, tree)

    if not sql_exists(db, sql_key) do
      :ok = do_sql_store(db, sql_key, tree)
    end

    sql_key
  end

  defp do_sql_store(db, sql_key, {:leaf, _hash_count, prefix, bucket}) do
    sql_write(db, sql_key, {:leaf, nil, prefix, bucket})
  end

  defp do_sql_store(db, sql_key, {:node, hashcount = {_hash, count}, prefix, left, right}) do
    hashcount =
      if count > 16 do
        hashcount
      else
        nil
      end

    sql_write(
      db,
      sql_key,
      {:node, hashcount, prefix, do_sql_store(db, left), do_sql_store(db, right)}
    )
  end

  defp sql_write(db, key, val) do
    data = BertInt.encode!(val)
    Sql.query!(db, "REPLACE INTO mtree (hash, data) VALUES(?1, ?2)", bind: [key, data])
    :ok
  end

  defp sql_decode(val) do
    BertInt.decode!(val)
  end

  defp from_key(db, sql_key) when is_binary(sql_key) do
    [[data: data]] = Sql.query!(db, "SELECT data FROM mtree WHERE hash = ?1", bind: [sql_key])

    update_merkle_hash_count(db, sql_decode(data))
  end

  # ========================================================
  # Internal
  # ========================================================
  @leaf_size 16
  @left <<0::size(1)>>
  @right <<1::size(1)>>

  @spec do_get(pid(), tree(), binary(), binary()) :: any()
  defp do_get(db, sql_key, key, hash) when is_binary(sql_key) do
    do_get(db, from_key(db, sql_key), key, hash)
  end

  defp do_get(db, {:node, _hash_count, prefix, left, right}, key, hash) do
    case decide(hash, prefix) do
      true -> do_get(db, left, key, hash)
      false -> do_get(db, right, key, hash)
    end
  end

  defp do_get(_db, {:leaf, _hash_count, _prefix, bucket}, key, _hash) do
    Map.get(bucket, key)
  end

  @spec do_get_proofs(pid(), tree(), binary(), binary()) :: any()
  defp do_get_proofs(db, sql_key, key, hash) when is_binary(sql_key) do
    do_get_proofs(db, from_key(db, sql_key), key, hash)
  end

  defp do_get_proofs(db, {:node, _hash_count, prefix, left, right}, key, hash) do
    case decide(hash, prefix) do
      true -> {do_get_proofs(db, left, key, hash), merkle_hash(db, right, hash)}
      false -> {merkle_hash(db, left, hash), do_get_proofs(db, right, key, hash)}
    end
  end

  defp do_get_proofs(_db, {:leaf, _hash_count, prefix, bucket}, key, _hash) do
    bucket_to_leaf(bucket, prefix, key)
  end

  defp do_size(db, sql_key) when is_binary(sql_key) do
    do_size(db, from_key(db, sql_key))
  end

  defp do_size(_db, {:leaf, _hash_count, _prefix, bucket}) do
    map_size(bucket)
  end

  defp do_size(db, {:node, nil, _prefix, left, right}) do
    do_size(db, left) + do_size(db, right)
  end

  defp do_size(_db, {:node, {_hashes, count}, _prefix, _left, _right}) do
    count
  end

  defp do_bucket_count(db, sql_key) when is_binary(sql_key) do
    do_bucket_count(db, from_key(db, sql_key))
  end

  defp do_bucket_count(_db, {:leaf, _hash_count, _prefix, _bucket}) do
    1
  end

  defp do_bucket_count(db, {:node, _hash_count, _prefix, left, right}) do
    do_bucket_count(db, left) + do_bucket_count(db, right)
  end

  defp do_to_list(db, sql_key) when is_binary(sql_key) do
    do_to_list(db, from_key(db, sql_key))
  end

  defp do_to_list(_db, {:leaf, _hash_count, _prefix, bucket}) do
    Map.to_list(bucket)
  end

  defp do_to_list(db, {:node, _hash_count, _prefix, left, right}) do
    do_to_list(db, left) ++ do_to_list(db, right)
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

  @spec update_bucket(pid(), tree(), binary(), fun()) :: tree()
  defp update_bucket(db, {:node, _hash_count, prefix, left, right}, key, fun) do
    case decide(key, prefix) do
      true ->
        {:node, nil, prefix, update_bucket(db, left, key, fun), right}

      false ->
        {:node, nil, prefix, left, update_bucket(db, right, key, fun)}
    end
  end

  defp update_bucket(_db, {:leaf, _hash_count, prefix, bucket}, _key, fun) do
    fun.({:leaf, nil, prefix, bucket})
  end

  defp update_bucket(db, sql_key, key, fun) when is_binary(sql_key) do
    update_bucket(db, from_key(db, sql_key), key, fun)
  end

  defp merkle_hash_count(tree) when is_tuple(tree) do
    elem(tree, 1)
  end

  defp merkle_hashes(_db, tree) when is_tuple(tree) do
    {hashes, _count} = merkle_hash_count(tree)
    hashes
  end

  defp merkle_hashes(db, sql_key) when is_binary(sql_key) do
    merkle_hashes(db, from_key(db, sql_key))
  end

  defp merkle_hash(db, tree, hash) do
    hashes = merkle_hashes(db, tree)
    Enum.at(hashes, hash_to_leafindex(hash))
  end

  defp hash_to_leafindex(hash) do
    <<lastb::unsigned-size(8)>> = binary_part(hash, byte_size(hash), -1)
    rem(lastb, @leaf_size)
  end

  @spec update_merkle_hash_count(pid(), tree()) :: tree()
  defp update_merkle_hash_count(db, {:node, nil, prefix, left, right}) do
    left = update_merkle_hash_count(db, left)
    {hashesl, countl} = merkle_hash_count(left)

    right = update_merkle_hash_count(db, right)
    {hashesr, countr} = merkle_hash_count(right)

    count = countl + countr
    # Need to merge
    if count <= @leaf_size do
      items = do_to_list(db, {:node, nil, prefix, left, right})

      tree = {:leaf, nil, prefix, Map.new(items)}
      update_merkle_hash_count(db, tree)
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

  defp update_merkle_hash_count(db, {:leaf, nil, prefix, bucket}) do
    count = map_size(bucket)
    # Need to split
    if count > @leaf_size do
      {left, right} = Enum.split_with(bucket, fn item -> decide(key(item), prefix) end)

      tree =
        {:node, nil, prefix, {:leaf, nil, <<prefix::bitstring, @left::bitstring>>, Map.new(left)},
         {:leaf, nil, <<prefix::bitstring, @right::bitstring>>, Map.new(right)}}

      update_merkle_hash_count(db, tree)
    else
      hashes =
        bucket_to_leafes(bucket, prefix)
        |> Enum.map(&signature/1)

      {:leaf, {hashes, count}, prefix, bucket}
    end
  end

  # Loading reduced nodes (where hash_count = nil because it was skipped during storage)
  defp update_merkle_hash_count(db, sql_key) when is_binary(sql_key) do
    update_merkle_hash_count(db, from_key(db, sql_key))
  end

  defp update_merkle_hash_count(_db, tree) when is_tuple(tree) do
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

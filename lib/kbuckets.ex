defmodule KBuckets do
  @moduledoc """
  Provides 256 bits k-buckets for hashes
  """
  alias Object.Server, as: Server
  import Wallet

  defmodule Item do
    defstruct node_id: nil, last_seen: nil, object: nil
  end

  defimpl String.Chars, for: Item do
    def to_string(item) do
      String.Chars.to_string(Map.from_struct(item))
    end
  end

  @type item :: %Item{node_id: Wallet.t(), last_seen: integer, object: Server.server() | :self}

  @type item_id :: <<_::256>>
  @type node_id :: Wallet.t()
  @type tree :: {:leaf, any(), map()} | {:node, any(), tree(), tree()}
  @type kbuckets :: {:kbucket, any(), tree() | nil}

  @k 20
  @zero <<0::size(1)>>
  @one <<1::size(1)>>

  @spec new(node_id()) :: kbuckets()
  def new(self_id = wallet()) do
    {:kbucket, self_id,
     {:leaf, "",
      %{
        self_id => self({:kbucket, self_id, nil})
      }}}
  end

  @spec self(kbuckets()) :: item()
  def self({:kbucket, self_id, _tree}) do
    %Item{node_id: self_id, last_seen: -1, object: :self}
  end

  def object(%Item{object: :self}) do
    Diode.self()
  end

  def object(%Item{object: server}) do
    server
  end

  @spec to_uri(item()) :: binary()
  def to_uri(item) do
    server = object(item)
    host = Server.host(server)
    port = Server.server_port(server)
    "diode://#{item.node_id}@#{host}:#{port}"
  end

  @spec size(kbuckets()) :: non_neg_integer()
  def size({:kbucket, _self_id, tree}) do
    do_size(tree)
  end

  defp do_size({:leaf, _prefix, bucket}) do
    map_size(bucket)
  end

  defp do_size({:node, _prefix, zero, one}) do
    do_size(zero) + do_size(one)
  end

  @spec bucket_count(kbuckets()) :: pos_integer()
  def bucket_count({:kbucket, _self_id, tree}) do
    do_bucket_count(tree)
  end

  defp do_bucket_count({:leaf, _prefix, _bucket}) do
    1
  end

  defp do_bucket_count({:node, _prefix, zero, one}) do
    do_bucket_count(zero) + do_bucket_count(one)
  end

  @spec to_list(kbuckets()) :: [item()]
  def to_list({:kbucket, _self_id, tree}) do
    do_to_list(tree)
  end

  defp do_to_list({:leaf, _prefix, bucket}) do
    Map.values(bucket)
  end

  defp do_to_list({:node, _prefix, zero, one}) do
    do_to_list(zero) ++ do_to_list(one)
  end

  @spec nearest_n(kbuckets() | [item()], item() | item_id(), pos_integer()) :: [item()]
  def nearest_n({:kbucket, self, tree}, item, n) do
    min_dist = distance(hash(self), item)

    do_nearest_n(tree, key(item), n)
    # Selecting down to nearest items
    |> nearest_n(item, n)
    |> Enum.filter(fn a -> distance(a, item) <= min_dist end)
  end

  def nearest_n(list, item, n) when is_list(list) do
    list
    |> Enum.sort(fn a, b -> distance(item, a) < distance(item, b) end)
    |> Enum.take(n)
  end

  def unique(list) when is_list(list) do
    Enum.reduce(list, %{}, fn node, acc ->
      Map.put(acc, key(node), node)
    end)
    |> Map.values()
  end

  @doc """
    Calculates the linear distance on a geometric ring from 0 to 2^256 any distance.
    Because it's a ring the maximal distance is two points being opposite of each
    other. In that case the distance is 2^255.

    2^256 = 0xffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff
    2^255 = 0x7fffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff

  """
  def distance(a, b) do
    dist = abs(integer(key(a)) - integer(key(b)))

    if dist > 0x7FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF do
      0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF - dist
    else
      dist
    end
  end

  def hash(wallet() = w) do
    Diode.hash(Wallet.address!(w))
  end

  def hash(value) when is_binary(value) do
    Diode.hash(value)
  end

  # Converting secp256k into 256 hash by removing the first byte
  def key(%Item{node_id: w}) do
    hash(w)
  end

  def key(<<key::bitstring-size(256)>>) do
    key
  end

  defp do_nearest_n({:leaf, _prefix, bucket}, _key, _n) do
    Map.values(bucket)
  end

  defp do_nearest_n({:node, prefix, zero, one}, key, n) do
    x = bit_size(prefix)

    {far, near} =
      case key do
        <<^prefix::bitstring-size(x), @zero::bitstring, _::bitstring>> ->
          {one, zero}

        <<^prefix::bitstring-size(x), @one::bitstring, _::bitstring>> ->
          {zero, one}
      end

    result = do_nearest_n(near, key, n)

    if length(result) < n do
      result ++ Enum.take(do_to_list(far), n - length(result))
    else
      result
    end
  end

  @spec delete_item(kbuckets(), item() | item_id()) :: kbuckets()
  def delete_item({:kbucket, self_id, tree}, item) do
    key = key(item)

    tree =
      update_bucket(tree, key, fn {:leaf, prefix, bucket} ->
        {:leaf, prefix, Map.delete(bucket, key)}
      end)

    {:kbucket, self_id, tree}
  end

  def member?(list, item) when is_list(list) do
    Enum.any?(list, fn a -> key(a) == key(item) end)
  end

  def member?(kb, item) do
    kb != delete_item(kb, item)
  end

  @spec insert_item(kbuckets(), item() | item_id()) :: kbuckets()
  def insert_item({:kbucket, self_id, tree}, item) do
    {:kbucket, self_id, do_insert_item(tree, item)}
  end

  @spec insert_items(kbuckets(), [item()]) :: kbuckets()
  def insert_items({:kbucket, self_id, tree}, items) do
    tree =
      Enum.reduce(items, tree, fn item, acc ->
        do_insert_item(acc, item)
      end)

    {:kbucket, self_id, tree}
  end

  defp do_insert_item(tree, item) do
    key = key(item)

    update_bucket(tree, key, fn orig ->
      {:leaf, prefix, bucket} = orig
      bucket = Map.put(bucket, key, item)

      if map_size(bucket) < @k do
        {:leaf, prefix, bucket}
      else
        if is_self(bucket) do
          new_node =
            {:node, prefix, {:leaf, <<prefix::bitstring, @zero::bitstring>>, %{}},
             {:leaf, <<prefix::bitstring, @one::bitstring>>, %{}}}

          Enum.reduce(bucket, new_node, fn {_, node}, acc ->
            do_insert_item(acc, node)
          end)
        else
          # ignoring the item
          orig
        end
      end
    end)
  end

  defp update_bucket({:node, prefix, zero, one}, key, fun) do
    x = bit_size(prefix)

    case key do
      <<^prefix::bitstring-size(x), @zero::bitstring, _::bitstring>> ->
        {:node, prefix, update_bucket(zero, key, fun), one}

      <<^prefix::bitstring-size(x), @one::bitstring, _::bitstring>> ->
        {:node, prefix, zero, update_bucket(one, key, fun)}
    end
  end

  defp update_bucket({:leaf, prefix, bucket}, _key, fun) do
    fun.({:leaf, prefix, bucket})
  end

  @spec k() :: integer()
  def k() do
    @k
  end

  def is_self(%Item{object: :self}) do
    true
  end

  def is_self(%Item{}) do
    false
  end

  def is_self(bucket) do
    Enum.any?(bucket, fn {_, item} -> is_self(item) end)
  end

  defp integer(key) do
    <<x::integer-size(256)>> = key
    x
  end
end

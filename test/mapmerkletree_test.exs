# Diode Server
# Copyright 2021 Diode
# Licensed under the Diode License, Version 1.1
defmodule MapMerkleTreeTest do
  use ExUnit.Case

  defp new() do
    MapMerkleTree.new()
  end

  test "initialize" do
    tree = new()
    assert MerkleTree.size(tree) == 0
    assert MerkleTree.bucket_count(tree) == 1
  end

  test "inserts" do
    tree = new()

    size = 16

    tree =
      Enum.reduce(pairs(size), tree, fn item, acc ->
        MerkleTree.insert_item(acc, item)
      end)

    assert MerkleTree.size(tree) == size
    assert MerkleTree.bucket_count(tree) == 1
  end

  test "number conversion" do
    data = %{
      <<0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
        0,
        0>> =>
        <<0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
          0, 0, 1>>,
      <<0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
        0,
        1>> =>
        <<0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
          0, 0, 1>>,
      <<0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
        0,
        3>> =>
        <<0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 169, 79, 83, 116, 252, 229, 237, 188, 142, 42, 134,
          151, 193, 83, 49, 103, 126, 110, 191, 11>>,
      <<0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
        1,
        7>> =>
        <<0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
          0, 69, 254>>,
      <<110, 54, 152, 54, 72, 124, 35, 75, 158, 85, 62, 243, 247, 135, 194, 216, 134, 85, 32, 115,
        157, 52, 12, 103, 179, 210, 81, 163, 57, 134, 229,
        141>> =>
        <<0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
          0, 0, 1>>
    }

    tree =
      Enum.reduce(data, new(), fn {key, value}, tree ->
        value = :binary.decode_unsigned(value)
        value = <<value::unsigned-size(256)>>
        key = :binary.decode_unsigned(key)
        MerkleTree.insert(tree, key, value)
      end)

    for {key, value} <- data do
      key = :binary.decode_unsigned(key)
      assert MerkleTree.get(tree, key) == value
    end
  end

  test "no duplicate" do
    tree =
      new()
      |> MerkleTree.insert_item({"a", 1})
      |> MerkleTree.insert_item({"a", 2})

    assert MerkleTree.size(tree) == 1
  end

  test "no nulls" do
    tree =
      new()
      |> MerkleTree.insert_item({"a", 1})
      |> MerkleTree.insert_item({"a", 0})

    assert MerkleTree.size(tree) == 0
  end

  test "proof" do
    size = 20
    tree0 = new()

    tree20 =
      Enum.reduce(pairs(size), tree0, fn item, acc ->
        MerkleTree.insert_item(acc, item)
      end)

    roots = MerkleTree.root_hashes(tree20)

    for {{k, v}, idx} <- Enum.with_index(pairs(10 * size)) do
      proofs = MerkleTree.get_proofs(tree20, k)
      proof = proof(proofs)

      [prefix, pos | values] = value(proofs)
      x = bit_size(prefix)
      <<key_prefix::bitstring-size(x), _::bitstring>> = hash(k)
      <<last_byte>> = binary_part(hash(k), byte_size(hash(k)), -1)

      # Checking that this proof connects to the root
      assert Enum.member?(roots, proof)

      # Checking that the provided range is for the given keys prefix
      assert key_prefix == prefix

      # Checking that the provided leaf matches the given key
      assert rem(last_byte, 16) == pos

      if idx < size do
        assert :proplists.get_value(k, values) == v
      else
        assert :proplists.get_value(k, values) == :undefined
      end

      # IO.puts("#{byte_size(BertExt.encode!(proofs))} (#{length(values)})")
    end
  end

  test "equality" do
    size = 20
    tree = new()

    tree20 =
      Enum.reduce(pairs(size), tree, fn item, acc ->
        MerkleTree.insert_item(acc, item)
      end)

    tree20r =
      Enum.reduce(Enum.reverse(pairs(size)), tree, fn item, acc ->
        MerkleTree.insert_item(acc, item)
      end)

    assert MerkleTree.root_hash(tree20) == MerkleTree.root_hash(tree20r)
    assert tree20 == tree20r
  end

  test "deletes" do
    size = 20
    sizeh = div(size, 2)

    tree0 = new()

    tree20 =
      Enum.reduce(pairs(size), tree0, fn item, acc ->
        MerkleTree.insert_item(acc, item)
      end)

    assert MerkleTree.size(tree20) == size
    assert MerkleTree.bucket_count(tree20) == 2

    tree10 =
      Enum.reduce(pairs(sizeh), tree20, fn {key, _}, acc ->
        MerkleTree.delete(acc, key)
      end)

    assert MerkleTree.size(tree10) == sizeh
    assert MerkleTree.bucket_count(tree10) == 1

    tree0v2 =
      Enum.reduce(pairs(size), tree20, fn {key, _}, acc ->
        MerkleTree.delete(acc, key)
      end)

    assert MerkleTree.size(tree0v2) == 0
    assert MerkleTree.bucket_count(tree10) == 1
    assert MerkleTree.root_hash(tree0v2) == MerkleTree.root_hash(tree0)
  end

  defp pairs(num) do
    Enum.map(1..num, fn idx ->
      {"#{idx}", Diode.hash("#{idx}")}
    end)
  end

  defp value(list) when is_list(list) do
    list
  end

  defp value({left, right}) do
    value(left) || value(right)
  end

  defp value(hash) when is_binary(hash) do
    false
  end

  defp proof(list) when is_list(list) do
    # :io.format("Erlang: ~p~nBert: ~p~n", [list, BertExt.encode!(list)])
    hash(BertExt.encode!(list))
  end

  defp proof({left, right}) do
    list = [proof(left), proof(right)]
    hash(BertExt.encode!(list))
  end

  defp proof(hash) when is_binary(hash) do
    hash
  end

  defp hash(value) when is_binary(value) do
    Diode.hash(value)
  end

  # defp encode(mixed) when is_tuple(mixed) do
  #   List.to_tuple(encode(Tuple.to_list(mixed)))
  # end

  # defp encode(hashes) when is_list(hashes) do
  #   Enum.map(hashes, &encode/1)
  # end

  # defp encode(hash = <<_::binary-size(32)>>) do
  #   :base64.encode(hash)
  # end

  # defp encode(term) do
  #   term
  # end
end

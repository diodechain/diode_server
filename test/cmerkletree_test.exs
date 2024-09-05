# Diode Server
# Copyright 2021-2024 Diode
# Licensed under the Diode License, Version 1.1
defmodule CMerkleTreeTest do
  use ExUnit.Case

  defp new() do
    CMerkleTree.new()
  end

  test "initialize" do
    tree = new()
    assert CMerkleTree.size(tree) == 0
    assert CMerkleTree.bucket_count(tree) == 1
  end

  test "inserts" do
    tree = new()

    size = 16

    tree =
      Enum.reduce(pairs(size), tree, fn item, acc ->
        CMerkleTree.insert_item(acc, item)
      end)

    assert CMerkleTree.size(tree) == size
    assert CMerkleTree.bucket_count(tree) == 1
  end

  test "difference" do
    [a, b, c, d] = pairs(20) |> Enum.chunk_every(5)
    [a2, _b2, _c2, _d2] = pairs(20, "2") |> Enum.chunk_every(5)

    tree_a = CMerkleTree.from_list(a ++ b ++ c)
    tree_b = CMerkleTree.from_list(a2 ++ b ++ d)

    diff = CMerkleTree.difference(tree_a, tree_b)

    assert diff == %{
             "                               1" =>
               {<<107, 134, 178, 115, 255, 52, 252, 225, 157, 107, 128, 78, 255, 90, 63, 87, 71,
                  173, 164, 234, 162, 47, 29, 73, 192, 30, 82, 221, 183, 135, 91, 75>>,
                <<107, 81, 212, 49, 223, 93, 127, 20, 28, 190, 206, 204, 247, 158, 223, 61, 216,
                  97, 195, 180, 6, 159, 11, 17, 102, 26, 62, 239, 172, 187, 169, 24>>},
             "                               2" =>
               {<<212, 115, 94, 58, 38, 94, 22, 238, 224, 63, 89, 113, 139, 155, 93, 3, 1, 156, 7,
                  216, 182, 197, 31, 144, 218, 58, 102, 110, 236, 19, 171, 53>>,
                <<120, 95, 62, 199, 235, 50, 243, 11, 144, 205, 15, 207, 54, 87, 211, 136, 181,
                  255, 66, 151, 242, 249, 113, 111, 246, 110, 155, 105, 192, 93, 221, 9>>},
             "                               3" =>
               {<<78, 7, 64, 133, 98, 190, 219, 139, 96, 206, 5, 193, 222, 207, 227, 173, 22, 183,
                  34, 48, 150, 125, 224, 31, 100, 11, 126, 71, 41, 180, 159, 206>>,
                <<226, 156, 156, 24, 12, 98, 121, 176, 176, 42, 189, 106, 24, 1, 199, 192, 64,
                  130, 207, 72, 110, 192, 39, 170, 19, 81, 94, 79, 56, 132, 187, 107>>},
             "                               4" =>
               {<<75, 34, 119, 119, 212, 221, 31, 198, 28, 111, 136, 79, 72, 100, 29, 2, 180, 209,
                  33, 211, 253, 50, 140, 176, 139, 85, 49, 252, 172, 218, 191, 138>>,
                <<115, 71, 92, 180, 10, 86, 142, 141, 168, 160, 69, 206, 209, 16, 19, 126, 21,
                  159, 137, 10, 196, 218, 136, 59, 107, 23, 220, 101, 27, 58, 128, 73>>},
             "                               5" =>
               {<<239, 45, 18, 125, 227, 123, 148, 43, 170, 208, 97, 69, 229, 75, 12, 97, 154, 31,
                  34, 50, 123, 46, 187, 207, 190, 199, 143, 85, 100, 175, 227, 157>>,
                <<65, 207, 192, 209, 242, 209, 39, 176, 69, 85, 183, 36, 109, 132, 1, 155, 77, 39,
                  113, 10, 63, 58, 255, 110, 119, 100, 55, 91, 30, 6, 224, 93>>},
             "                              11" =>
               {<<79, 200, 43, 38, 174, 203, 71, 210, 134, 140, 78, 251, 227, 88, 23, 50, 163,
                  231, 203, 204, 108, 46, 251, 50, 6, 44, 8, 23, 10, 5, 238, 184>>, nil},
             "                              12" =>
               {<<107, 81, 212, 49, 223, 93, 127, 20, 28, 190, 206, 204, 247, 158, 223, 61, 216,
                  97, 195, 180, 6, 159, 11, 17, 102, 26, 62, 239, 172, 187, 169, 24>>, nil},
             "                              13" =>
               {<<63, 219, 163, 95, 4, 220, 140, 70, 41, 134, 201, 146, 188, 248, 117, 84, 98, 87,
                  17, 48, 114, 169, 9, 193, 98, 247, 228, 112, 229, 129, 226, 120>>, nil},
             "                              14" =>
               {<<133, 39, 168, 145, 226, 36, 19, 105, 80, 255, 50, 202, 33, 43, 69, 188, 147,
                  246, 159, 187, 128, 28, 59, 30, 190, 218, 197, 39, 117, 249, 158, 97>>, nil},
             "                              15" =>
               {<<230, 41, 250, 101, 152, 215, 50, 118, 143, 124, 114, 107, 75, 98, 18, 133, 249,
                  195, 184, 83, 3, 144, 10, 169, 18, 1, 125, 183, 97, 125, 139, 219>>, nil},
             "                              16" =>
               {nil,
                <<177, 126, 246, 209, 156, 122, 91, 30, 232, 59, 144, 124, 89, 85, 38, 220, 177,
                  235, 6, 219, 130, 39, 214, 80, 213, 221, 160, 169, 244, 206, 140, 217>>},
             "                              17" =>
               {nil,
                <<69, 35, 84, 15, 21, 4, 205, 23, 16, 12, 72, 53, 232, 91, 126, 239, 212, 153, 17,
                  88, 15, 142, 255, 240, 89, 154, 143, 40, 59, 230, 185, 227>>},
             "                              18" =>
               {nil,
                <<78, 201, 89, 159, 194, 3, 209, 118, 163, 1, 83, 108, 46, 9, 26, 25, 188, 133,
                  39, 89, 178, 85, 189, 104, 24, 129, 10, 66, 197, 254, 209, 74>>},
             "                              19" =>
               {nil,
                <<148, 0, 241, 178, 28, 181, 39, 215, 250, 61, 62, 171, 186, 147, 85, 122, 24,
                  235, 231, 162, 202, 78, 71, 28, 254, 94, 76, 91, 76, 167, 247, 103>>},
             "                              20" =>
               {nil,
                <<245, 202, 56, 247, 72, 161, 214, 234, 247, 38, 184, 164, 47, 181, 117, 195, 199,
                  31, 24, 100, 168, 20, 51, 1, 120, 45, 225, 61, 162, 217, 32, 43>>}
           }
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
        CMerkleTree.insert(tree, key, value)
      end)

    for {key, value} <- data do
      key = :binary.decode_unsigned(key)
      assert CMerkleTree.get(tree, key) == value
    end
  end

  test "no duplicate" do
    tree =
      new()
      |> CMerkleTree.insert_item({"a", 1})
      |> CMerkleTree.insert_item({"a", 2})

    assert CMerkleTree.size(tree) == 1

    assert CMerkleTree.to_list(tree) == [{"a", <<0::unsigned-size(248), 2>>}]
  end

  test "clone" do
    {data1, data2} = Enum.sort(pairs(128)) |> Enum.split(64)

    tree1 = new() |> CMerkleTree.insert_items(data1)
    assert CMerkleTree.size(tree1) == 64

    tree2 = CMerkleTree.clone(tree1)
    assert CMerkleTree.size(tree2) == 64
    assert CMerkleTree.root_hash(tree1) == CMerkleTree.root_hash(tree2)

    tree2 = CMerkleTree.insert_items(tree2, data2)
    assert CMerkleTree.size(tree2) == 128
    assert CMerkleTree.size(tree1) == 64
    assert CMerkleTree.root_hash(tree1) != CMerkleTree.root_hash(tree2)
  end

  test "no nulls" do
    tree =
      new()
      |> CMerkleTree.insert_item({"a", 1})
      |> CMerkleTree.insert_item({"a", 0})

    assert CMerkleTree.size(tree) == 0
  end

  test "proof" do
    size = 20
    tree0 = new()

    tree20 =
      Enum.reduce(pairs(size), tree0, fn item, acc ->
        CMerkleTree.insert_item(acc, item)
      end)

    roots = CMerkleTree.root_hashes(tree20)

    for {{k, v}, idx} <- Enum.with_index(pairs(10 * size)) do
      proofs = CMerkleTree.get_proofs(tree20, k)

      if idx == 0 do
        assert proofs ==
                 {[
                    <<0::size(1)>>,
                    15,
                    {"                               1",
                     <<107, 134, 178, 115, 255, 52, 252, 225, 157, 107, 128, 78, 255, 90, 63, 87,
                       71, 173, 164, 234, 162, 47, 29, 73, 192, 30, 82, 221, 183, 135, 91, 75>>}
                  ],
                  <<213, 245, 42, 124, 119, 38, 179, 149, 177, 91, 192, 217, 115, 78, 97, 97, 159,
                    59, 6, 21, 61, 126, 252, 97, 248, 135, 154, 180, 92, 208, 105, 18>>}
      end

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
        CMerkleTree.insert_item(acc, item)
      end)

    tree20r =
      Enum.reduce(Enum.reverse(pairs(size)), tree, fn item, acc ->
        CMerkleTree.insert_item(acc, item)
      end)

    assert CMerkleTree.root_hash(tree20) == CMerkleTree.root_hash(tree20r)
    assert tree20 == tree20r
  end

  test "deletes" do
    size = 20
    sizeh = div(size, 2)

    tree0 = new()

    tree20 =
      Enum.reduce(pairs(size), tree0, fn item, acc ->
        CMerkleTree.insert_item(acc, item)
      end)

    assert CMerkleTree.size(tree20) == size
    assert CMerkleTree.bucket_count(tree20) == 2

    tree10 =
      Enum.reduce(pairs(sizeh), tree20, fn {key, _}, acc ->
        CMerkleTree.delete(acc, key)
      end)

    assert CMerkleTree.size(tree10) == sizeh
    assert CMerkleTree.bucket_count(tree10) == 1

    tree0v2 =
      Enum.reduce(pairs(size), tree20, fn {key, _}, acc ->
        CMerkleTree.delete(acc, key)
      end)

    assert CMerkleTree.size(tree0v2) == 0
    assert CMerkleTree.bucket_count(tree10) == 1
    assert CMerkleTree.root_hash(tree0v2) == CMerkleTree.root_hash(tree0)
  end

  defp pairs(num, variant \\ "") do
    Enum.map(1..num, fn idx ->
      {String.pad_leading("#{idx}", 32), CMerkleTree.hash("#{idx}" <> variant)}
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

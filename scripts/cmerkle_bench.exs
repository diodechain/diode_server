# size = 10_000
# ref = Base16.decode("0x96c2b5d03aa8e52230e74d9a08359c38c7608e5d9aba18773f3c90baf3806ccb")

Application.ensure_all_started(:weak_ref)

size = 1000
ref = Base16.decode("0xe3545ad7961427b2a49d0b0a7b4a61e040acaefc432b69bcc1066b7c8c460a6b")
# ref = Base16.decode("0x3b99d56aa16278d50e85a8ea0939e62180c4f0305b773775f1844c3303a41897") 100_000

test_data =
  Enum.map(1..size, fn idx ->
    hash = Diode.hash("!#{idx}!")
    {hash, hash}
  end)

none = spawn(fn ->
  EtsLru.new(:cmerkle, 5)
  Process.sleep(:infinity)
end)


for i <- 1..1000000 do
  time_ms = :timer.tc(fn ->
    tree_size = 1000
    tree_size_1 = tree_size + 1
    for _ <- 1..tree_size do
      a = CMerkleTree.hash("b1000000!")
      item = {a, a}

      WeakRef.new(none)

      tree = CMerkleTree.insert_items(CMerkleTree.new(), test_data) |> CMerkleTree.lock()
      tree2 = CMerkleTree.clone(tree)
        |> CMerkleTree.lock()
        |> CMerkleTree.clone()
        |> CMerkleTree.lock()
        |> CMerkleTree.clone()
        |> CMerkleTree.lock()
        |> CMerkleTree.clone()
        |> CMerkleTree.lock()
        |> CMerkleTree.clone()
        |> CMerkleTree.lock()
        |> CMerkleTree.clone()
        |> CMerkleTree.lock()
        |> CMerkleTree.clone()
        |> CMerkleTree.insert_items([item])

      _proof = tree2 |> CMerkleTree.get_proofs(a)
      _proof2 = tree |> CMerkleTree.get_proofs(a)
      ^tree_size = CMerkleTree.size(tree)
      ^tree_size = CMerkleTree.to_list(tree) |> length()
      ^tree_size_1 = CMerkleTree.size(tree2)
      ^tree_size_1 = CMerkleTree.to_list(tree2) |> length()
      92 = CMerkleTree.bucket_count(tree)
      92 = CMerkleTree.bucket_count(tree2)

      %{^a => {nil, b}} = CMerkleTree.difference(tree, tree2)
      CMerkleTree.from_map(%{a => b})

      nil = CMerkleTree.get(tree, a)
      ^a = CMerkleTree.get(tree2, a)


      if CMerkleTree.root_hash(tree) != ref do
        raise("Error #{Base16.encode(CMerkleTree.root_hash(tree))} != #{Base16.encode(ref)}")
      end

      EtsLru.put(:cmerkle, CMerkleTree.root_hash(tree), tree)
    end
  end)
  |> elem(0)
  |> div(1000)

  IO.puts("Run #{i} #{time_ms}ms")
  :erlang.garbage_collect()
end

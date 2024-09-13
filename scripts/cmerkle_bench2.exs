# size = 10_000
# ref = Base16.decode("0x96c2b5d03aa8e52230e74d9a08359c38c7608e5d9aba18773f3c90baf3806ccb")

Application.ensure_all_started(:weak_ref)

size = 1000
ref = Base16.decode("0xe3545ad7961427b2a49d0b0a7b4a61e040acaefc432b69bcc1066b7c8c460a6b")
# ref = Base16.decode("0x3b99d56aa16278d50e85a8ea0939e62180c4f0305b773775f1844c3303a41897") 100_000

for i <- 1..1000000 do
  time_ms = :timer.tc(fn ->
    tree_size = 1000
    for _ <- 1..tree_size do
      test_data =
        Enum.map(1..size, fn idx ->
          hash = Diode.hash("!#{idx}!")
          {hash, hash}
        end)

      tree = CMerkleTree.new()
      for {key, value} <- test_data do
        CMerkleTree.insert_item(tree, {key, value})
      end
      for {key, value} <- test_data do
        ^value = CMerkleTree.get(tree, key)
      end
      ^tree_size = length(CMerkleTree.to_list(tree))

      if CMerkleTree.root_hash(tree) != ref do
        raise("Error #{Base16.encode(CMerkleTree.root_hash(tree))} != #{Base16.encode(ref)}")
      end

    end
  end)
  |> elem(0)
  |> div(1000)

  IO.puts("Run #{i} #{time_ms}ms")
  :erlang.garbage_collect()
end

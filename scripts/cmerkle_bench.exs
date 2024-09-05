# size = 10_000
# ref = Base16.decode("0x96c2b5d03aa8e52230e74d9a08359c38c7608e5d9aba18773f3c90baf3806ccb")

size = 100_000
ref = Base16.decode("0x3b99d56aa16278d50e85a8ea0939e62180c4f0305b773775f1844c3303a41897")

test_data =
  Enum.map(1..size, fn idx ->
    hash = Diode.hash("!#{idx}!")
    {hash, hash}
  end)

for i <- 1..3 do
  time_ms = :timer.tc(fn ->
    for _ <- 1..100 do
      tree = CMerkleTree.insert_items(CMerkleTree.new(), test_data)

      if CMerkleTree.root_hash(tree) != ref do
        raise("Error #{Base16.encode(CMerkleTree.root_hash(tree))} != #{Base16.encode(ref)}")
      end
    end
  end)
  |> elem(0)
  |> div(1000)

  IO.puts("Run #{i} #{time_ms}ms")
end

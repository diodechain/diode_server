rpcs = File.read!("test/data/stress.json") |> Poison.decode!()
Network.Rpc.handle_jsonrpc(rpcs, [])

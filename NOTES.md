# Command line perf testing reference

## 21. Feb 2022 - e97191192cc022452d2167beea24f06939cac6f8

```elixir
rpc = fn method, args -> :timer.tc(fn -> Network.EdgeV2.handle_async_msg([method, Rlpx.num2bin(Chain.peak()) | args], nil) end) end
id = <<237, 217, 116, 65, 255, 170, 122, 217, 206, 132, 246, 126, 210, 93, 83, 13, 230, 107, 130, 135>>
slot1 = <<5, 127, 142, 10, 91, 52, 106, 14, 9, 229, 29, 19, 3, 97, 232, 18, 212, 29, 88, 37, 185, 216, 147, 129, 123, 167, 254, 18, 252, 9, 230, 157>>
slot2 = <<27, 241, 228, 27, 25, 19, 64, 172, 238, 203, 185, 176, 129, 254, 154, 178, 131, 5, 167, 1, 226, 25, 216, 229, 150, 121, 1, 130, 59, 28, 70, 179>>
slot3 = <<27, 241, 228, 27, 25, 19, 64, 172, 238, 203, 185, 176, 129, 254, 154, 178, 131, 5, 167, 1, 226, 25, 216, 229, 150, 121, 1, 130, 59, 28, 70, 180>>
slot4 = <<27, 241, 228, 27, 25, 19, 64, 172, 238, 203, 185, 176, 129, 254, 154, 178, 131, 5, 167, 1, 226, 25, 216, 229, 150, 121, 1, 130, 59, 28, 70, 181>>

> :timer.tc(fn -> Chain.with_peak(&Chain.Block.blockquick_window/1) end) |> elem(0)
324

> rpc.("getstateroots", []) |> elem(0)
124

> rpc.("getaccount", [id]) |> elem(0)
200

> rpc.("getaccountroots", [id]) |> elem(0)
900

> rpc.("getaccountvalue", [id, slot1]) |> elem(0)
> rpc.("getaccountvalue", [id, slot2]) |> elem(0)
900

> rpc.("getaccountvalues", [id, slot1, slot2, slot3, slot4]) |> elem(0)
1000

> :timer.tc(fn ->
    rpc.("getaccountvalue", [id, slot1])
    rpc.("getaccountvalue", [id, slot2])
    rpc.("getaccountvalue", [id, slot3])
    rpc.("getaccountvalue", [id, slot4])
end) |> elem(0)
4000

```

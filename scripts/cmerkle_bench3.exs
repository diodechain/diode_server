Application.ensure_all_started(:mutable_map)


# uncompact = fn %Chain.State{accounts: old_accounts}->
#   Enum.reduce(old_accounts, MutableMap.new(), fn {id, acc}, accounts ->
#     MutableMap.put(accounts, id, Chain.Account.uncompact(acc))
#   end)
# end


EtsLru.new(:leak_state, 15)
state = File.read!("leak_state.bin")

for i <- 1..100 do
  one = EtsLru.fetch(:leak_state, i, fn ->
    ret = :erlang.binary_to_term(state)
    |> Chain.State.uncompact()
    |> Chain.State.lock()
    # |> IO.inspect()

    :erlang.garbage_collect()
    :erlang.garbage_collect(Process.whereis(MutableMap.Beacon))

      ret
  end)

  IO.puts("#{i}: #{map_size(one)}")
end

# NIF-only uncompact for Valgrind profiling (same 14k fixture as chain_state_uncompact_test).
# No full app.start — only loads the NIF via CAccountMap.new/0.
alias Chain.State

_ = CAccountMap.new()

account_count = String.to_integer(System.get_env("UNCOMPACT_PROFILE_COUNT", "14609"))
fixture = Path.join(System.tmp_dir!(), "diode_uncompact_perf_14609.bin")

state =
  if File.exists?(fixture) do
    fixture |> File.read!() |> :erlang.binary_to_term()
  else
    raise "missing #{fixture}; run: mix test test/chain_state_uncompact_test.exs --only callgrind --include slow"
  end

accounts =
  if account_count < 14_609 do
    state.accounts
    |> Enum.take(account_count)
    |> Map.new()
  else
    state.accounts
  end

state = %{state | accounts: accounts}
IO.puts(:stderr, "uncompact starting (#{map_size(accounts)} accounts)")

restored = State.uncompact(state)

size = CAccountMap.size(restored.accounts)
IO.puts("uncompact ok: #{size} accounts")

if size != map_size(accounts) do
  System.halt(1)
end

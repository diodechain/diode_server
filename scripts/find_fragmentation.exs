percent = fn
  _a, 0 -> "100%"
  a, b -> "#{round(100 * a / b)}%"
end

get = fn
  nil, _key -> 0
  info, key ->
    elem(List.keyfind(info, key, 0), 1)
end

get_alloc = fn
  nil -> 0
  [head | _] -> elem(head, 2)
end

allocators = [:sys_alloc, :temp_alloc, :sl_alloc, :std_alloc, :ll_alloc,
  :eheap_alloc, :ets_alloc, :fix_alloc, :literal_alloc, :exec_alloc,
  :binary_alloc, :driver_alloc, :mseg_alloc]

Enum.each(allocators, fn alloc ->
  info = try do
    :erlang.system_info({:allocator, alloc})
  rescue
    _ -> nil
  end

  if is_list(info) do
    {allocated, used, calls} = Enum.reduce(info, {0, 0, 0}, fn
      {:instance, _nr, stats}, {al, us, ca} ->
        mbcs = Keyword.get(stats, :mbcs)
        allocated = get.(mbcs, :carriers_size)
        used = case Keyword.get(stats, :mbcs, []) |> Keyword.get(:blocks) do
          nil -> get.(mbcs, :blocks_size)
          {_, _, _, _} -> get.(mbcs, :blocks_size)
          list when is_list(list) ->
            Enum.reduce(list, 0, fn {_, other}, sum -> sum + get.(other, :size) end)
        end
        calls = get_alloc.(Keyword.get(stats, :calls))
        {allocated + al, used + us, calls + ca}
      _, acc -> acc
    end)

    waste = allocated - used
    IO.puts(
      "#{String.pad_trailing(to_string(alloc), 14)} got #{String.pad_leading("#{used}", 10)} used of #{String.pad_leading("#{allocated}", 10)} alloc (#{String.pad_leading(percent.(used, allocated), 4)}) = #{String.pad_leading("#{waste}", 10)} waste @ #{String.pad_leading("#{calls}", 10)} calls"
    )
  else
    IO.puts("#{String.pad_trailing(to_string(alloc), 14)} is disabled")
  end
end)

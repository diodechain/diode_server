#!/usr/bin/env elixir

# elixir inspect_mem.exs 5434
pid = Enum.at(System.argv(), 0) || raise "Missing argument"

memory = File.read!("/proc/#{pid}/maps")
  |> String.split("\n", trim: true)
  |> Enum.map(fn row ->
    [range, access, _offset, _device, _inode | path] = String.split(row, " ", trim: true)
    [start, stop] = String.split(range, "-")
    size = String.to_integer(stop, 16) - String.to_integer(start, 16)
    {size, range, access, path}
  end)
  |> Enum.filter(fn {_, _, access, _} -> access in ["rw-p", "r--p"] end)
  |> Enum.sort(:desc)

Enum.each(memory, fn row ->
    IO.inspect(row)
end)

total = Enum.map(memory, fn {size, _, _, _} -> size end) |> Enum.sum()
small = Enum.filter(memory, fn {size, _, _, _} -> size <= 32768 end)
  |> Enum.map(fn {size, _, _, _} -> size end) |> Enum.sum()


IO.puts("Total memory #{total} small entries: #{small}")

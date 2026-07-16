# Diode Server
# Copyright 2021-2024 Diode
# Licensed under the Diode License, Version 1.1
defmodule CountZerosTest do
  use ExUnit.Case

  # Reference: count zero bytes (same semantics as legacy Niffler / EVM gas calc).
  defp ref_count_zeros(bin), do: Enum.count(:binary.bin_to_list(bin), &(&1 == 0))

  describe "count_zeros" do
    test "matches reference for edge and random payloads" do
      bins = [
        <<>>,
        <<0>>,
        <<255>>,
        <<0, 0, 0>>,
        <<0, 1, 2, 0>>,
        :crypto.strong_rand_bytes(256)
      ]

      for bin <- bins do
        assert CMerkleTree.count_zeros(bin) == ref_count_zeros(bin)
      end
    end
  end
end

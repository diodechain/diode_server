# Diode Server
# Copyright 2021-2024 Diode
# Licensed under the Diode License, Version 1.1
#
# Production NIF surface after bare-tree removal: count_zeros + nif_stats + account_map_*.
defmodule CMerkleNifSurfaceTest do
  use ExUnit.Case, async: true

  test "nif_stats returns a four-integer monitor tuple" do
    {locked, orphans, shared, resources} = CMerkleTree.nif_stats()
    assert is_integer(locked) and locked >= 0
    assert is_integer(orphans) and orphans >= 0
    assert is_integer(shared) and shared >= 0
    assert is_integer(resources) and resources >= 0
  end

  test "account_map_new loads and reports size zero" do
    map = CAccountMap.new()
    assert CAccountMap.size(map) == 0
    assert CAccountMap.to_list(map) == []
  end
end

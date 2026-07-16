# Diode Server
# Copyright 2021-2024 Diode
# Licensed under the Diode License, Version 1.1
defmodule MemoryGuardTest do
  use ExUnit.Case, async: true

  test "read_rss_kb returns a positive integer on Linux" do
    rss = MemoryGuard.read_rss_kb()
    assert is_integer(rss)
    assert rss > 0
  end
end

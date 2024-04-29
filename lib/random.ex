# Diode Server
# Copyright 2021-2024 Diode
# Licensed under the Diode License, Version 1.1
defmodule Random do
  @moduledoc """
  Random provides random aliases for the range of machine types
  uint8-uint64, int8-int64 as well as additional aliases uint8h-uint64h
  generating random numbers starting at the lower types range end.
  """

  def uint8(), do: random(0, 255)
  def uint16(), do: random(0, 65535)
  def uint32(), do: random(0, 4_294_967_295)

  def uint63(), do: random(0, 9_223_372_036_854_775_807)
  def uint64(), do: random(0, 18_446_744_073_709_551_615)
  def int8(), do: random(-128, 127)
  def int16(), do: random(-32768, 32767)
  def int32(), do: random(-2_147_483_648, 2_147_483_647)
  def int64(), do: random(-9_223_372_036_854_775_808, 9_223_372_036_854_775_807)

  def uint8h(), do: random(16, 255)
  def uint16h(), do: random(255, 65535)
  def uint31h(), do: random(65535, 2_147_483_647)
  def uint32h(), do: random(65535, 4_294_967_295)
  def uint63h(), do: random(4_294_967_295, 9_223_372_036_854_775_807)
  def uint64h(), do: random(4_294_967_295, 18_446_744_073_709_551_615)

  @spec random(integer(), integer()) :: integer()
  def random(lo, hi) do
    :rand.uniform(hi - lo) + lo
  end
end

# Diode Server
# Copyright 2019 IoT Blockchain Technology Corporation LLC (IBTC)
# Licensed under the Diode License, Version 1.0
defmodule Rlpx do
  @moduledoc """
  Rlpx defines helepr method for converting RLP encoded values back and forth.
  """
  @type rlp() :: binary() | [rlp()]

  @spec hex2num(binary()) :: non_neg_integer()
  def hex2num("") do
    0
  end

  def hex2num(bin) when is_binary(bin) do
    bin2num(Base16.decode(bin))
  end

  @spec num2bin(non_neg_integer) :: binary
  def num2bin(0) do
    ""
  end

  def num2bin(num) when is_integer(num) do
    :binary.encode_unsigned(num)
  end

  @spec bin2num(binary()) :: non_neg_integer()
  def bin2num("") do
    0
  end

  def bin2num(bin) when is_binary(bin) do
    :binary.decode_unsigned(bin)
  end

  @spec bin2int(binary) :: integer
  def bin2int(bin) when is_binary(bin) do
    num = bin2num(bin)

    case rem(num, 2) do
      0 -> div(num, 2)
      1 -> -div(num - 1, 2)
    end
  end

  def int2bin(int) when is_integer(int) do
    if int < 0 do
      -(int * 2) + 1
    else
      int * 2
    end
    |> :binary.encode_unsigned()
  end

  @spec hex2addr(binary()) :: nil | binary()
  def hex2addr("") do
    nil
  end

  def hex2addr(bin) when is_binary(bin) do
    bin2addr(Base16.decode(bin))
  end

  @spec bin2addr(binary()) :: nil | binary()
  def bin2addr("") do
    nil
  end

  def bin2addr(bin) when is_binary(bin) do
    bin
  end

  def list2map(list) do
    Enum.map(list, fn [key, value] -> {key, value} end)
    |> Map.new()
  end
end

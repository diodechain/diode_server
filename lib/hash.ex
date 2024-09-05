# Diode Server
# Copyright 2021-2024 Diode
# Licensed under the Diode License, Version 1.1
defmodule Hash do
  @spec integer(binary()) :: non_neg_integer()
  def integer(hash) do
    :binary.decode_unsigned(hash)
  end

  def to_bytes32(hash = <<_::256>>) do
    hash
  end

  def to_bytes32(hash = <<_::160>>) do
    <<0::96, hash::binary-size(20)>>
  end

  def to_bytes32(hash) when is_integer(hash) do
    <<hash::unsigned-big-size(256)>>
  end

  def printable(nil) do
    "nil"
  end

  def printable(binary) do
    Base16.encode(binary)
  end

  def to_address(hash = <<_::160>>) do
    hash
  end

  def to_address(hash = <<_::256>>) do
    binary_part(hash, 12, 20)
  end

  def to_address(int) when is_integer(int) do
    <<int::160>>
  end

  def keccak_256(string) do
    :keccakf1600.hash(:sha3_256, string)
  end

  def sha2_256(string) do
    :crypto.hash(:sha256, string)
  end

  def ripemd160(string) do
    :crypto.hash(:ripemd160, string)
  end
end

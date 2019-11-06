# Diode Server
# Copyright 2019 IoT Blockchain Technology Corporation LLC (IBTC)
# Licensed under the Diode License, Version 1.0
defmodule Hash do
  @spec integer(binary()) :: non_neg_integer()
  def integer(hash) do
    :binary.decode_unsigned(hash)
  end

  def to_address(hash = <<_::160>>) do
    hash
  end

  def to_address(hash = <<_::256>>) do
    binary_part(hash, 12, 20)
  end

  def keccak_256(string) do
    :keccakf1600.hash(:sha3_256, string)
  end

  def sha3_256(string) do
    :crypto.hash(:sha256, string)
  end

  def ripemd160(string) do
    :crypto.hash(:ripemd160, string)
  end
end

# Diode Server
# Copyright 2021-2024 Diode
# Licensed under the Diode License, Version 1.1
defmodule PreCompiles do
  def get(1), do: &ecrecover/2
  def get(2), do: &sha256/2
  def get(3), do: &ripemd160/2
  def get(4), do: &copy/2
  # 6 => &b256Add/2,
  # 7 => &b256Mul/2,
  # 8 => &b256Pairing/2,
  def get(_), do: nil

  def ecrecover(:gas, _bytes) do
    3000
  end

  def ecrecover(
        :run,
        <<digest::binary-size(32), 0::unsigned-size(248), signature::binary-size(65), _::binary>>
      ) do
    <<recid::binary-size(1), r::binary-size(32), s::binary-size(32)>> = signature

    try do
      Secp256k1.rlp_to_bitcoin(recid, r, s)
      |> Secp256k1.recover!(digest, :none)
      |> Wallet.from_pubkey()
      |> Wallet.address!()
    rescue
      _ -> <<0::160>>
    end
  end

  def sha256(:gas, bytes) do
    div(byte_size(bytes) + 31, 32) * 12 + 60
  end

  def sha256(:run, bytes) do
    Hash.sha2_256(bytes)
  end

  def ripemd160(:gas, bytes) do
    div(byte_size(bytes) + 31, 32) * 120 + 600
  end

  def ripemd160(:run, bytes) do
    Hash.ripemd160(bytes)
  end

  def copy(:gas, bytes) do
    div(byte_size(bytes) + 31, 32) * 3 + 15
  end

  def copy(:run, bytes) do
    bytes
  end

  def modExp(
        :gas,
        <<baselen::unsigned-size(256), explen::unsigned-size(256), modlen::unsigned-size(256),
          _rest::binary>>
      ) do
    gas = max(modlen, baselen)

    gas =
      cond do
        gas <= 64 ->
          gas * gas

        gas <= 1024 ->
          div(gas * gas, 4) + (96 * gas - 3072)

        true ->
          div(gas * gas, 16) + (480 * gas - 199_680)
      end

    gas = gas * max(1, (explen - 32) * 8)
    gas = div(gas, 20)
    min(gas, 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF)
  end

  def modExp(
        :run,
        <<baselen::unsigned-size(256), explen::unsigned-size(256), modlen::unsigned-size(256),
          rest::binary>>
      ) do
    baselen8 = baselen * 8
    explen8 = explen * 8
    modlen8 = modlen * 8

    <<base::unsigned-size(baselen8), exp::unsigned-size(explen8), mod::unsigned-size(modlen8)>> =
      rest

    if (baselen == 0 and modlen == 0) or mod == 0 do
      ""
    else
      <<pow(base, base, exp, mod)::unsigned-size(modlen8)>>
    end
  end

  defp pow(ret, _base, 1, mod) do
    rem(ret, mod)
  end

  defp pow(ret, base, exp, mod) do
    pow(rem(ret * base, mod), base, exp - 1, mod)
  end
end

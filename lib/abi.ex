# Diode Server
# Copyright 2021 Diode
# Licensed under the Diode License, Version 1.1
defmodule ABI do
  import Wallet

  def encode_args(types, values) when is_list(types) and is_list(values) do
    encode_data(types, values)
    |> :erlang.iolist_to_binary()
  end

  def decode_revert(<<"">>) do
    {:evmc_revert, ""}
  end

  # Decoding "Error(string)" type revert messages
  def decode_revert(
        <<8, 195, 121, 160, 32::unsigned-size(256), length::unsigned-size(256), rest::binary>>
      ) do
    {:evmc_revert, binary_part(rest, 0, length)}
  end

  def decode_revert(other) do
    :io.format("DEBUG: decode_revert(~0p)~n", [other])
    {:evmc_revert, "blubb"}
  end

  def encode_spec(name, types \\ []) do
    signature = "#{name}(#{Enum.join(types, ",")})"
    binary_part(Hash.keccak_256(signature), 0, 4)
  end

  def encode_call(name, types \\ [], values \\ []) do
    fun = ABI.encode_spec(name, types)
    args = ABI.encode_args(types, values)
    fun <> args
  end

  def do_encode_data(type, value) do
    subtype = subtype(type)

    if subtype != nil do
      {types, values, len} = dynamic(type, value)
      ret = encode_data(types, values)
      {"", [encode("uint", len), ret]}
    else
      {encode(type, value), ""}
    end
  end

  def encode_data(subtypes, values) do
    values =
      Enum.zip([subtypes, values])
      |> Enum.map(fn {type, entry} ->
        do_encode_data(type, entry)
      end)

    {head, body, _} =
      Enum.reduce(values, {[], [], 32 * length(subtypes)}, fn
        {"", body}, {h, b, o} ->
          {h ++ [encode("uint", o)], b ++ [body], o + :erlang.iolist_size(body)}

        {head, _}, {h, b, o} ->
          {h ++ [head], b, o}
      end)

    [head, body]
  end

  @doc """
  subtype returns the individual element type of an dynamic/array
  """
  @spec subtype(binary) :: false | binary
  def subtype(type) do
    cond do
      String.ends_with?(type, "[]") -> binary_part(type, 0, byte_size(type) - 2)
      type == "bytes" -> "uint8"
      type == "string" -> "uint8"
      true -> nil
    end
  end

  def dynamic(type, values) when is_list(values) do
    {List.duplicate(subtype(type), length(values)), values, length(values)}
  end

  def dynamic(_type, value) when is_binary(value) do
    values = value <> <<0::unsigned-size(248)>>

    values =
      binary_part(values, 0, div(byte_size(values), 32) * 32)
      |> :erlang.binary_to_list()
      |> Enum.chunk_every(32)
      |> Enum.map(&:erlang.iolist_to_binary/1)

    {List.duplicate("bytes32", length(values)), values, byte_size(value)}
  end

  def encode(format, nil), do: encode(format, 0)

  # uint<M>: unsigned integer type of M bits, 0 < M <= 256, M % 8 == 0. e.g. uint32, uint8, uint256.
  # int<M>: two’s complement signed integer type of M bits, 0 < M <= 256, M % 8 == 0.
  # address: equivalent to uint160, except for the assumed interpretation and language typing. For computing the function selector, address is used.
  # uint, int: synonyms for uint256, int256 respectively. For computing the function selector, uint256 and int256 have to be used.
  # bool: equivalent to uint8 restricted to the values 0 and 1. For computing the function selector, bool is used.
  # fixed<M>x<N>: signed fixed-point decimal number of M bits, 8 <= M <= 256, M % 8 ==0, and 0 < N <= 80, which denotes the value v as v / (10 ** N).
  # ufixed<M>x<N>: unsigned variant of fixed<M>x<N>.
  # fixed, ufixed: synonyms for fixed128x18, ufixed128x18 respectively. For computing the function selector, fixed128x18 and ufixed128x18 have to be used.
  # bytes<M>: binary type of M bytes, 0 < M <= 32.
  # function: an address (20 bytes) followed by a function selector (4 bytes). Encoded identical to bytes24.
  for bit <- 1..32 do
    Module.eval_quoted(
      __MODULE__,
      Code.string_to_quoted("""
        def encode("uint#{bit * 8}", value), do: <<value :: unsigned-size(256)>>
        def encode("int#{bit * 8}", value), do: <<value :: signed-size(256)>>
        def encode("bytes#{bit}", <<value :: binary>>), do: <<:binary.decode_unsigned(value) :: unsigned-size(256)>>
        def encode("bytes#{bit}", value) when is_integer(value), do: <<value :: unsigned-size(256)>>
      """)
    )
  end

  def encode("uint", value), do: encode("uint256", value)
  def encode("int", value), do: encode("int256", value)
  def encode("address", value) when is_integer(value), do: encode("uint160", value)
  def encode("address", value) when is_binary(value), do: encode("bytes20", value)
  def encode("address", value = wallet()), do: encode("bytes20", Wallet.address!(value))
  def encode("bool", true), do: encode("uint8", 1)
  def encode("bool", false), do: encode("uint8", 0)
  def encode("bool", value), do: encode("uint8", value)

  def encode("function", {address, name}),
    do: encode("bytes24", encode("address", address) <> encode_spec(name))

  def encode("function", {address, name, types}),
    do: encode("bytes24", encode("address", address) <> encode_spec(name, types))

  def encode("function", value), do: encode("bytes24", value)
end

# Diode Server
# Copyright 2019 IoT Blockchain Technology Corporation LLC (IBTC)
# Licensed under the Diode License, Version 1.0
defmodule Rlp do
  @type rlp() :: binary() | [rlp()]

  @spec encode!(nil | binary() | maybe_improper_list() | non_neg_integer() | tuple()) :: binary()
  def encode!(<<x>>) when x < 0x80, do: <<x>>

  def encode!(x) when is_binary(x) do
    with_length!(0x80, x)
  end

  def encode!(list) when is_list(list) do
    with_length!(0xC0, Enum.map(list, &encode!/1))
  end

  def encode!(other) do
    encode!(do_encode!(other))
  end

  defp with_length!(offset, data) do
    size = :erlang.iolist_size(data)

    if size <= 55 do
      [offset + size, data]
    else
      bin = :binary.encode_unsigned(size)
      [byte_size(bin) + offset + 55, bin, data]
    end
    |> :erlang.iolist_to_binary()
  end

  @spec decode!(binary()) :: rlp()
  def decode!(bin) do
    {term, ""} = do_decode!(bin)
    term
  end

  defp do_encode!(nil) do
    ""
  end

  defp do_encode!(struct) when is_struct(struct) do
    Map.from_struct(struct)
    |> Enum.map(fn {key, value} -> [Atom.to_string(key), value] end)
  end

  defp do_encode!(map) when is_map(map) do
    Map.to_list(map)
    |> Enum.map(fn {key, value} ->
      [if(is_atom(key), do: Atom.to_string(key), else: key), value]
    end)
  end

  defp do_encode!(tuple) when is_tuple(tuple) do
    :erlang.tuple_to_list(tuple)
  end

  defp do_encode!(bits) when is_bitstring(bits) do
    for <<x::size(1) <- bits>>, do: if(x == 1, do: "1", else: "0"), into: ""
  end

  defp do_encode!(0) do
    # Sucks but this is the quasi standard by Go and Node.js
    # This is why we have bin2num
    ""
  end

  defp do_encode!(num) when is_integer(num) do
    :binary.encode_unsigned(num)
  end

  defp do_decode!(<<x::unsigned-size(8), rest::binary>>) when x <= 0x7F do
    {<<x::unsigned>>, rest}
  end

  defp do_decode!(<<head::unsigned-size(8), rest::binary>>) when head <= 0xB7 do
    size = head - 0x80
    <<item::binary-size(size), rest::binary>> = rest
    {item, rest}
  end

  defp do_decode!(<<head::unsigned-size(8), rest::binary>>) when head <= 0xBF do
    length_size = (head - 0xB7) * 8
    <<size::unsigned-size(length_size), item::binary-size(size), rest::binary>> = rest
    {item, rest}
  end

  defp do_decode!(<<head::unsigned-size(8), rest::binary>>) when head <= 0xF7 do
    size = head - 0xC0
    <<list::binary-size(size), rest::binary>> = rest
    {do_decode_list!([], list), rest}
  end

  defp do_decode!(<<head::unsigned-size(8), rest::binary>>) when head <= 0xFF do
    length_size = (head - 0xF7) * 8
    <<size::unsigned-size(length_size), list::binary-size(size), rest::binary>> = rest
    {do_decode_list!([], list), rest}
  end

  defp do_decode_list!(list, "") do
    Enum.reverse(list)
  end

  defp do_decode_list!(list, rest) do
    {item, rest} = do_decode!(rest)
    do_decode_list!([item | list], rest)
  end
end

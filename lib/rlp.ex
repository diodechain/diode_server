# Diode Server
# Copyright 2019 IoT Blockchain Technology Corporation LLC (IBTC)
# Licensed under the Diode License, Version 1.0
defmodule Rlp do
  @type rlp() :: binary() | [rlp()]

  @spec encode!(nil | binary() | maybe_improper_list() | non_neg_integer() | tuple()) :: binary()
  def encode!(term) do
    :erlang.iolist_to_binary(do_encode!(term))
  end

  @spec decode!(binary()) :: rlp()
  def decode!(bin) do
    {term, ""} = do_decode!(bin)
    term
  end

  @spec hex2num(binary()) :: non_neg_integer()
  def hex2num("") do
    0
  end

  def hex2num(bin) when is_binary(bin) do
    bin2num(Base16.decode(bin))
  end

  @spec bin2num(binary()) :: non_neg_integer()
  def bin2num("") do
    0
  end

  def bin2num(bin) when is_binary(bin) do
    :binary.decode_unsigned(bin)
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

  defp do_encode!(nil) do
    do_encode!("")
  end

  defp do_encode!(struct) when is_struct(struct) do
    do_encode!(
      Map.from_struct(struct)
      |> Enum.map(fn {key, value} -> [Atom.to_string(key), value] end)
    )
  end

  defp do_encode!(map) when is_map(map) do
    encode!(
      Map.to_list(map)
      |> Enum.map(fn {key, value} ->
        [if(is_atom(key), do: Atom.to_string(key), else: key), value]
      end)
    )
  end

  defp do_encode!(tuple) when is_tuple(tuple) do
    encode!(:erlang.tuple_to_list(tuple))
  end

  defp do_encode!(list) when is_list(list) do
    list = Enum.map(list, &do_encode!/1)
    size = :erlang.iolist_size(list)

    head =
      if size <= 55 do
        0xC0 + size
      else
        bin_length = encode_length(size)
        [0xF7 + byte_size(bin_length), bin_length]
      end

    [head, list]
  end

  defp do_encode!(bin = <<x::unsigned-size(8)>>) when x <= 0x7F do
    bin
  end

  defp do_encode!(bin) when is_binary(bin) do
    head =
      if byte_size(bin) <= 55 do
        0x80 + byte_size(bin)
      else
        bin_length = encode_length(byte_size(bin))
        [0xB7 + byte_size(bin_length), bin_length]
      end

    [head, bin]
  end

  defp do_encode!(bits) when is_bitstring(bits) do
    for <<x::size(1) <- bits>>, do: if(x == 1, do: "1", else: "0"), into: ""
  end

  defp do_encode!(0) do
    # Sucks but this is the quasi standard by Go and Node.js
    # This is why we have bin2num
    do_encode!("")
  end

  defp do_encode!(num) when is_integer(num) do
    do_encode!(:binary.encode_unsigned(num))
  end

  defp do_decode!(<<x::unsigned-size(8), rest::binary>>) when x <= 0x7F do
    {<<x::unsigned>>, rest}
  end

  defp do_decode!(<<head::unsigned-size(8), rest::binary>>) when head <= 0xB7 do
    size = head - 0x80
    <<item::binary-size(size), rest::binary>> = rest
    {item, rest}
  end

  defp do_decode!(<<head::unsigned-size(8), rest::binary>>) when head <= 0xC0 do
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

  # defp decode_length(<<)

  defp encode_length(size) do
    cond do
      size <= 0xFF ->
        <<size::unsigned-size(8)>>

      size <= 0xFFFF ->
        <<size::unsigned-size(16)>>
    end
  end
end

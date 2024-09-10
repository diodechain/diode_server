# Diode Server
# Copyright 2021-2024 Diode
# Licensed under the Diode License, Version 1.1
defmodule Json do
  def encode!(object, conv \\ []) do
    prepare!(object, conv)
    |> Poison.encode!()
  end

  def prepare!(object, conv \\ []) do
    do_encode(object, conv_validate(conv))
  end

  defp conv_validate(conv) do
    conv
  end

  def decode!(binary) do
    {:ok, result} = decode(binary)
    result
  end

  def decode(binary) do
    case Poison.decode(binary) do
      {:ok, object} ->
        {:ok, do_decode(object)}
        # other -> other
    end
  end

  defp do_encode(map, conv) when is_map(map) do
    Enum.into(
      Enum.map(Map.to_list(map), fn {key, value} ->
        {do_encode(key, conv), do_encode(value, conv)}
      end),
      %{}
    )
  end

  defp do_encode(list, conv) when is_list(list) do
    Enum.map(list, &do_encode(&1, conv))
  end

  defp do_encode({:raw, num}, _conv) do
    num
  end

  defp do_encode(tuple, conv) when is_tuple(tuple) do
    Tuple.to_list(tuple)
    |> Enum.map(&do_encode(&1, conv))
  end

  defp do_encode(int, _conv) when is_integer(int) and int >= 0 do
    case Base16.encode(int, false) do
      "0x0" <> rest -> "0x" <> rest
      other -> other
    end
  end

  defp do_encode("", _conv) do
    "0x"
  end

  defp do_encode(bin, _conv) when is_binary(bin) do
    if String.printable?(bin) do
      bin
    else
      Base16.encode(bin, false)
    end
  end

  defp do_encode(bits, _conv) when is_bitstring(bits) do
    for <<x::size(1) <- bits>>, do: if(x == 1, do: "1", else: "0"), into: ""
  end

  defp do_encode(other, _conv) do
    other
  end

  defp do_decode(map) when is_map(map) do
    Enum.into(
      Enum.map(Map.to_list(map), fn {key, value} ->
        {key, do_decode(value)}
      end),
      %{}
    )
  end

  defp do_decode(list) when is_list(list) do
    Enum.map(list, &do_decode(&1))
  end

  defp do_decode(bin) when is_binary(bin) do
    case bin do
      <<"0x", _rest::binary>> ->
        Base16.decode(bin)

      <<"0X", _rest::binary>> ->
        Base16.decode(bin)

      other ->
        other
    end
  end

  defp do_decode(other) do
    other
  end
end

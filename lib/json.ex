defmodule Json do
  def encode!(object, bigX \\ true) do
    encodable = do_encode(object, bigX)
    Poison.encode!(encodable)
  end

  def prepare!(object, bigX \\ true) do
    do_encode(object, bigX)
  end

  def decode!(binary) do
    {:ok, result} = decode(binary)
    result
  end

  def decode(binary) do
    case Poison.decode(binary) do
      {:ok, object} -> {:ok, do_decode(object)}
      other -> other
    end
  end

  defp do_encode(map, bigX) when is_map(map) do
    Enum.into(
      Enum.map(Map.to_list(map), fn {key, value} ->
        {key, do_encode(value, bigX)}
      end),
      %{}
    )
  end

  defp do_encode(list, bigX) when is_list(list) do
    Enum.map(list, &do_encode(&1, bigX))
  end

  defp do_encode({:raw, num}, _bigX) when is_integer(num) do
    num
  end

  defp do_encode(tuple, bigX) when is_tuple(tuple) do
    Tuple.to_list(tuple)
    |> Enum.map(&do_encode(&1, bigX))
  end

  defp do_encode(int, bigX) when is_integer(int) and int >= 0 do
    Base16.encode(int, bigX)
  end

  defp do_encode(bin, bigX) when is_binary(bin) do
    if String.printable?(bin) do
      bin
    else
      Base16.encode(bin, bigX)
    end
  end

  defp do_encode(bits, _bigX) when is_bitstring(bits) do
    for <<x::size(1) <- bits>>, do: if(x == 1, do: "1", else: "0"), into: ""
  end

  defp do_encode(other, _bigX) do
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
      <<"base58:", rest::binary>> ->
        :base58.base58_to_binary(:erlang.binary_to_list(rest))

      <<"base32:", rest::binary>> ->
        :base32.decode(:erlang.binary_to_list(rest))

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

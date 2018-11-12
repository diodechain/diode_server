defmodule Object do
  @moduledoc """
    All objects are made of tuples {:type, value1, value2, ..., valueN, signature}
    The number of values are different but the last signature is a signature is
    always is the signature of BertExt.encode!([value1, value2, ..., valueN]))
    Also the signatures public key is always equal to the key
  """
  @type key :: <<_::120>>
  @callback key(tuple()) :: key()

  def decode!(bin) when is_binary(bin) do
    BertExt.decode!(bin)
    |> decode_list!()
  end

  def decode_list!([type | values]) do
    [recordname(type) | values]
    |> List.to_tuple()
  end

  def encode!(record) do
    encode_list!(record)
    |> BertExt.encode!()
  end

  def encode_list!(record) do
    [type | values] = Tuple.to_list(record)
    [extname(type) | values]
  end

  @spec key(tuple()) :: binary()
  def key(record) do
    modname(record).key(record)
  end

  defp modname(record) do
    name = Atom.to_string(elem(record, 0))

    "Elixir.Object.#{String.capitalize(name)}"
    |> String.to_atom()
  end

  defp extname(name) do
    case name do
      :location ->
        "location"

      :server ->
        "server"
        # _ -> nil
    end
  end

  defp recordname(name) do
    case name do
      "location" ->
        :location

      "server" ->
        :server
        # _ -> nil
    end
  end
end

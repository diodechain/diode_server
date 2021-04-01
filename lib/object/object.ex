# Diode Server
# Copyright 2021 Diode
# Licensed under the Diode License, Version 1.1
defmodule Object do
  @moduledoc """
    All objects are made of tuples {:type, value1, value2, ..., valueN, signature}
    The number of values are different but the last signature is a signature is
    always is the signature of BertExt.encode!([value1, value2, ..., valueN]))
    Also the signatures public key is always equal to the key
  """
  @type key :: <<_::160>>
  @callback key(tuple()) :: key()

  def decode!(bin) when is_binary(bin) do
    BertExt.decode!(bin)
    |> decode_list!()
  end

  def decode_list!([type | values]) do
    [recordname(type) | values]
    |> List.to_tuple()
  end

  def decode_rlp_list!([
        "ticket",
        server_id,
        block_num,
        fleet_contract,
        total_connections,
        total_bytes,
        local_address,
        device_signature,
        server_signature
      ]) do
    {:ticket, server_id, Rlpx.bin2num(block_num), fleet_contract, Rlpx.bin2num(total_connections),
     Rlpx.bin2num(total_bytes), local_address, device_signature, server_signature}
  end

  def decode_rlp_list!(["server", host, edge_port, peer_port, signature]) do
    {:server, host, Rlpx.bin2num(edge_port), Rlpx.bin2num(peer_port), signature}
  end

  def decode_rlp_list!(["server", host, edge_port, peer_port, version, extra, signature]) do
    extra = Enum.map(extra, fn [key, value] -> [key, Rlpx.bin2num(value)] end)
    {:server, host, Rlpx.bin2num(edge_port), Rlpx.bin2num(peer_port), version, extra, signature}
  end

  def decode_rlp_list!([
        "channel",
        server_id,
        block_num,
        fleet_contract,
        type,
        name,
        params,
        signature
      ]) do
    {:channel, server_id, Rlpx.bin2num(block_num), fleet_contract, type, name, params, signature}
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

  def ticket_id(record) do
    modname(record).ticket_id(record)
  end

  defp modname(record) do
    name = Atom.to_string(elem(record, 0))

    "Elixir.Object.#{String.capitalize(name)}"
    |> String.to_atom()
  end

  defp extname(name) do
    case name do
      :ticket -> "ticket"
      :server -> "server"
      :channel -> "channel"
    end
  end

  defp recordname(name) do
    case name do
      "ticket" -> :ticket
      "server" -> :server
      "channel" -> :channel
    end
  end
end

# Diode Server
# Copyright 2019 IoT Blockchain Technology Corporation LLC (IBTC)
# Licensed under the Diode License, Version 1.0
defmodule Object.Server do
  require Record
  @behaviour Object

  Record.defrecord(:server,
    host: nil,
    edge_port: nil,
    peer_port: nil,
    version: nil,
    extra: nil,
    signature: nil
  )

  @type server ::
          record(:server,
            host: binary(),
            edge_port: integer(),
            peer_port: integer(),
            version: binary(),
            extra: [],
            # extra: [[binary(), non_neg_integer()]],
            # Forward compatible place for new data here
            signature: Secp256k1.signature()
          )

  def new(host, edge_port, peer_port, version, extra \\ []) do
    server(host: host, peer_port: peer_port, edge_port: edge_port, version: version, extra: extra)
  end

  @spec key(server()) :: Object.key()
  def key(serv) do
    Secp256k1.recover!(signature(serv), message(serv))
    |> Wallet.from_pubkey()
    |> Wallet.address!()
  end

  def sign(serv, private) do
    len = tuple_size(serv)
    put_elem(serv, len - 1, Secp256k1.sign(private, message(serv)))
  end

  def host(serv) do
    elem(serv, 1)
  end

  def edge_port(serv) do
    elem(serv, 2)
  end

  def peer_port(serv) do
    elem(serv, 3)
  end

  def signature(serv) do
    len = tuple_size(serv)
    elem(serv, len - 1)
  end

  def uri(serv) do
    host = host(serv)
    port = peer_port(serv)
    key = Base16.encode(key(serv))
    "diode://#{key}@#{host}:#{port}"
  end

  defp message(serv) do
    Tuple.to_list(serv)
    |> Enum.slice(1, tuple_size(serv) - 2)
    |> BertExt.encode!()
  end
end

defmodule Object.Server do
  require Record
  @behaviour Object

  Record.defrecord(:server, host: nil, edge_port: nil, server_port: nil, signature: nil)

  @type server ::
          record(:server,
            host: binary(),
            edge_port: integer(),
            server_port: integer(),
            signature: Secp256k1.signature()
          )

  def new(host, server_port, edge_port) do
    server(host: host, server_port: server_port, edge_port: edge_port)
  end

  @spec key(server()) :: Object.key()
  def key(server(signature: signature) = rec) do
    Secp256k1.recover!(signature, message(rec))
    |> Wallet.from_pubkey()
    |> Wallet.address!()
  end

  def sign(server() = serv, private) do
    server(serv, signature: Secp256k1.sign(private, message(serv)))
  end

  def host(server(host: host)) do
    host
  end

  def edge_port(server(edge_port: port)) do
    port
  end

  def server_port(server(server_port: port)) do
    port
  end

  def signature(server(signature: signature)) do
    signature
  end

  def uri(server) do
    host = host(server)
    port = server_port(server)
    key = Base16.encode(key(server))
    "diode://#{key}@#{host}:#{port}"
  end

  defp message(server() = tuple) do
    Tuple.to_list(tuple)
    |> Enum.slice(1, tuple_size(tuple) - 2)
    |> BertExt.encode!()
  end
end

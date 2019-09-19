#! /usr/bin/elixir
# command = "openssl s_client -connect localhost:41043 -showcerts -msg -servername local -tls1_2 -tlsextdebug -curves secp256k1 -cert device_certificate.pem"
alias Object.Ticket, as: Ticket
import Ticket

defmodule Client do
  def check(_cert, event, state) do
    case event do
      {:bad_cert, :selfsigned_peer} -> {:valid, state}
      _ -> {:fail, event}
    end
  end

  def readloop(who) do
    line = String.trim(IO.read(:line))
    line = case Json.decode(line) do
      {:ok, _} ->
        line
      _ ->
        list = String.split(line, " ")
        |> Enum.map(fn(word) ->
          case Integer.parse(word) do
            {_, ""} -> word
            _ -> "\"#{word}\""
            end
        end)
        |> Enum.join(",")
        "[#{list}]"
    end
    send(who, {:line, line})
    readloop(who)
  end

  def call(state, cmd) do
    state = socksend(state, cmd)
    receive do
      {:ssl, _, msg} ->
        {%{state | unpaid_bytes: state.unpaid_bytes + byte_size(msg)}, Json.decode!(msg)}
    end
  end

  def init(state) do
    {state, ["response", "getblockpeak", peak]} = call(state, ~s(["getblockpeak"]))
    {state, ["response", "getblock", block]} = call(state, ~s(["getblock", #{peak}]))
    %{state | hash: block["header"]["block_hash"], peak: peak}
    # state
  end

  def socksend(state, data) do
    :ok = :ssl.send(state.socket, data)
    %{state | unpaid_bytes: state.unpaid_bytes + byte_size(data)}
  end

  def loop(state) do
    state = create_ticket(state)

    receive do
      {:ssl, _, msg} ->
        state = %{state | unpaid_bytes: state.unpaid_bytes + byte_size(msg)}

        case handle_tickets(state, msg) do
          false ->
            IO.puts(">> #{msg}")
            state

          state ->
            state
        end
        |> loop()

      {:ssl_closed, _} ->
        IO.puts("Remote closed the connection")

      {:line, "quit\n"} ->
        :ok

      {:line, line} ->
        state = socksend(state, line)
        loop(state)

      msg ->
        IO.puts("Unhandled: #{inspect(msg)}")
    end
  end

  defp create_ticket(state = %{unpaid_bytes: ub, paid_bytes: pb}) do
    # IO.puts("create_ticket(#{ub} >= #{pb} + 1024) = #{ub >= pb + 1024}")
    if ub >= pb + 1024 and not :persistent_term.get(:no_tickets) do
      do_create_ticket(state)
    else
      state
    end
  end

  defp do_create_ticket(state) do
    state = %{state | paid_bytes: state.paid_bytes + 1024}
    server_id = Wallet.from_pubkey(Certs.extract(state.socket)) |> Wallet.address!()
    bert = BertExt.encode!([
      server_id,
      state.hash,
      state.fleet,
      state.conns,
      state.paid_bytes,
      "spam"
    ])
    signature = Secp256k1.sign(state.key, bert)

    data = [
      "ticket",
      state.peak,
      state.fleet,
      state.conns,
      state.paid_bytes,
      "spam",
      signature
    ]
    # IO.puts("#{inspect data}")
    # IO.puts("#{inspect state}")

    socksend(state, Json.encode!(data))
  end

  def handle_tickets(state, msg) do
    if not :persistent_term.get(:no_tickets) do
      case Json.decode!(msg) do
        ["response", "ticket", "thanks!"] ->
          state

        ["response", "ticket", "too_low", _peak, conns, bytes, _address, _signature] ->
          state = %{state | conns: conns, paid_bytes: bytes, unpaid_bytes: bytes + 1024}
          create_ticket(state)

        _ ->
          false
      end
    else
      false
    end
  end
end

cert = "./client_lib/device_certificate.pem"

options = [
  mode: :binary,
  packet: 2,
  certfile: cert,
  cacertfile: cert,
  versions: [:"tlsv1.2"],
  verify: :verify_peer,
  verify_fun: {&Client.check/3, nil},
  fail_if_no_peer_cert: true,
  eccs: [:secp256k1],
  active: false,
  reuseaddr: true,
  keyfile: cert
]

:ssl.start()
{:ok, socket} = :ssl.connect('localhost', 41043, options, 5000)

:persistent_term.put(:no_tickets, false)

Process.spawn(Client, :readloop, [self()], [])
:ssl.setopts(socket, active: true)

%{
  socket: socket,
  paid_bytes: 0,
  unpaid_bytes: 0,
  peak: 0,
  hash: 0,
  conns: 0,
  key: Certs.private_from_file(cert),
  fleet: Diode.fleetAddress()
}
|> Client.init()
|> Client.loop()

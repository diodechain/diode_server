#!/usr/bin/elixir
# command = "openssl s_client -connect localhost:41043 -showcerts -msg -servername local -tls1_2 -tlsextdebug -curves secp256k1 -cert device_certificate.pem"
defmodule Client do
  def check(_cert, event, state) do
    case event do
      {:bad_cert, :selfsigned_peer} -> {:valid, state}
      _ -> {:fail, event}
    end
  end

  def readloop(who) do
    line = IO.read(:line)
    send(who, {:line, line})
    readloop(who)
  end

  def loop(socket) do
    receive do
      {:ssl, _, msg} ->
        IO.puts(">> #{msg}")
        loop(socket)
      {:ssl_closed, _} ->
        IO.puts("Remote closed the connection")
      {:line, "quit\n"} ->
        :ok
      {:line, line} ->
        :ok = :ssl.send(socket, line)
        loop(socket)
      msg ->
        IO.puts("Unhandled: #{inspect(msg)}")
    end
  end
end

options = [
  mode: :binary,
  packet: 2,
  certfile: "./device_certificate.pem",
  cacertfile: "./device_certificate.pem",
  versions: [:"tlsv1.2"],
  verify: :verify_peer,
  verify_fun: {&Client.check/3, nil},
  fail_if_no_peer_cert: true,
  eccs: [:secp256k1],
  active: false,
  reuseaddr: true,
  keyfile: "./device_certificate.pem",
]

:ssl.start()
{:ok, socket} = :ssl.connect('localhost', 41043, options, 5000)

Process.spawn(Client, :readloop, [self()], [])
:ssl.setopts(socket, active: true)
Client.loop(socket)



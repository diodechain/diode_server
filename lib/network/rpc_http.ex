# Diode Server
# Copyright 2021-2024 Diode
# Licensed under the Diode License, Version 1.1
defmodule Network.RpcHttp do
  use Plug.Router

  plug(
    Plug.Parsers,
    parsers: [:urlencoded, :json],
    json_decoder: Poison
  )

  plug(:match)
  plug(:dispatch)

  defp cors(conn) do
    headers = %{
      # "access-control-allow-credentials" => "true",
      "access-control-allow-origin" => "*",
      "access-control-allow-methods" => "POST, GET",
      "access-control-allow-headers" => "Content-Type",
      # "access-control-expose-headers" => "content-type",
      "content-type" => "application/json"
    }

    conn
    |> merge_resp_headers(headers)
  end

  options "/" do
    cors(conn) |> send_resp(204, "")
  end

  post "/" do
    conn = cors(conn)
    local = is_local(conn.remote_ip)
    {status, body} = Network.Rpc.handle_jsonrpc(conn.body_params, private: local)

    send_resp(conn, status, Poison.encode!(body))
  end

  match _ do
    send_resp(conn, 404, Poison.encode!("not found"))
  end

  defp is_local({127, 0, 0, _any}), do: true
  defp is_local(_conn), do: false
end

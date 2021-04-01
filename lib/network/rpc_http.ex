# Diode Server
# Copyright 2021 Diode
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
      "Access-Control-Allow-Origin" => "*",
      "Access-Control-Allow-Methods" => "POST, GET",
      "Access-Control-Allow-Headers" => "Content-Type",
      # "Access-Control-Expose-Headers" => "content-type",
      "Content-Type" => "application/json"
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

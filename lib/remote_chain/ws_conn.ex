# Diode Server
# Copyright 2021-2024 Diode
# Licensed under the Diode License, Version 1.1
defmodule RemoteChain.WSConn do
  @moduledoc """
  Manage websocket connections to the given chain rpc node
  """
  use WebSockex
  alias RemoteChain.WSConn
  require Logger

  defstruct [
    :owner,
    :chain,
    :ws_url,
    :conn,
    :lastblock_at,
    :subscription_id,
    lastblock_number: 0
  ]

  def start(owner, chain, ws_url) do
    state = %__MODULE__{
      owner: owner,
      chain: chain,
      ws_url: ws_url,
      lastblock_at: DateTime.utc_now()
    }

    {:ok, pid} =
      WebSockex.start(ws_url, __MODULE__, state, async: true, handle_initial_conn_failure: true)

    :timer.send_interval(chain.expected_block_intervall() * 2, pid, :ping)
    pid
  end

  @impl true
  def handle_connect(conn, state) do
    Process.monitor(state.owner)
    state = %{state | conn: conn}

    %{
      "jsonrpc" => "2.0",
      "id" => 1,
      "method" => "eth_subscribe",
      "params" => ["newHeads"]
    }
    |> Poison.encode!()
    |> send_frame(state)

    %{
      "jsonrpc" => "2.0",
      "id" => 2,
      "method" => "eth_blockNumber",
      "params" => []
    }
    |> Poison.encode!()
    |> send_frame(state)

    {:ok, state}
  end

  @impl true
  def handle_disconnect(%{reason: {:local, :normal}}, state) do
    {:ok, state}
  end

  def handle_disconnect(%{reason: reason}, state) do
    Logger.warning(
      "WSConn disconnected from #{inspect(state.chain)} for reason: #{inspect(reason)}"
    )

    {:ok, state}
  end

  def handle_disconnect(status, state) do
    Logger.warning("WSConn disconnected from #{inspect(state.chain)} for #{inspect(status)}")
    {:ok, state}
  end

  @impl true
  def handle_frame(
        {:text, json},
        state = %{ws_url: ws_url, chain: _chain, subscription_id: subscription_id}
      ) do
    case Poison.decode!(json) do
      %{"id" => 1, "result" => subscription_id} when is_binary(subscription_id) ->
        {:ok, %{state | subscription_id: subscription_id}}

      %{"id" => 2, "result" => <<"0", _x, hex_number::binary>>} ->
        state = new_block(hex_number, state)
        {:ok, state}

      %{
        "params" => %{
          "subscription" => ^subscription_id,
          "result" => %{"number" => <<"0", _x, hex_number::binary>>}
        }
      } ->
        state = new_block(hex_number, state)
        {:ok, state}

      %{"id" => _} = other ->
        send(state.owner, {:response, ws_url, other})
        {:ok, state}
    end
  end

  def handle_frame(other, state) do
    Logger.error("WSConn received unknown frame: #{inspect(other)}")
    {:ok, state}
  end

  @impl true
  # RemoteChain.RPC.block_number(Chains.Diode)
  def handle_cast({:send_request, request}, state) do
    send_frame(request, state)
    {:ok, state}
  end

  @impl true
  def handle_info(
        :ping,
        %WSConn{chain: chain, lastblock_at: lastblock_at, ws_url: ws_url} = state
      ) do
    age = DateTime.diff(DateTime.utc_now(), lastblock_at, :second)

    if age > chain.expected_block_intervall() * 4 do
      Logger.warning(
        "WSConn did not receive a block from #{chain} (#{ws_url}) since quad interval. Restarting..."
      )

      {:close, state}
    else
      {:ok, state}
    end
  end

  defp new_block(hex_number, state) do
    block_number = String.to_integer(hex_number, 16)
    # Logger.info("WSConn received block #{block_number} from #{state.ws_url}")
    send(state.owner, {:new_block, state.ws_url, block_number})
    %{state | lastblock_at: DateTime.utc_now(), lastblock_number: block_number}
  end

  defp send_frame(request, state) do
    {:ok, frame} = WebSockex.Frame.encode_frame({:text, request})
    :ok = WebSockex.Conn.socket_send(state.conn, frame)
  end
end

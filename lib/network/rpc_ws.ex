defmodule Network.RpcWs do
  @behaviour :cowboy_websocket_handler

  def init(_, _req, _opts) do
    {:upgrade, :protocol, :cowboy_websocket}
  end

  def websocket_init(_type, req, _opts) do
    {:ok, req, %{status: "inactive"}}
  end

  def websocket_handle({:ping, message}, req, state) do
    {:reply, {:pong, message}, req, state}
  end

  def websocket_handle({:text, message}, req, state) do
    ret =
      with {:ok, message} <- Poison.decode(message) do
        {_status, response} = Network.Rpc.handle_jsonrpc(message)
        {:reply, {:text, Poison.encode!(response)}, req, state}
      else
        {:ok, state} ->
          {:ok, req, state}

        _ ->
          {:reply, {:text, Poison.encode!("what?")}, req, state}
      end

    # :io.format("hdle(~330p)~n", [ret])

    ret
  end

  def websocket_terminate(_terminate_reason, _arg1, _state) do
    :ok
  end

  def websocket_info(any, req, state) do
    :io.format("rpc_ws:websocket_info(~p, ~p)~n", [any, req])
    {:ok, req, state}
  end
end

defmodule RemoteChain.Util do
  def batch_call(ref, calls, timeout \\ :infinity) do
    Enum.map(calls, fn call -> :gen_server.send_request(ref, call) end)
    |> Enum.map(fn req_id -> :gen_server.receive_response(req_id, timeout) end)
  end
end

ExUnit.start(seed: 0)

defmodule TestHelper do
  def reset() do
    Chain.reset_state()
    TicketStore.clear()
    wait(0)
    Chain.Worker.work()
    wait(1)
  end

  def wait(n) do
    case Chain.block(n) do
      %Chain.Block{} ->
        :ok

      _other ->
        :io.format("Waiting for block ~p~n", [n])
        Process.sleep(100)
        wait(n)
    end
  end
end

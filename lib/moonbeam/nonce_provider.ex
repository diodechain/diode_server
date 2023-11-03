defmodule Moonbeam.NonceProvider do
  alias Moonbeam.NonceProvider
  use GenServer
  require Logger

  defstruct [:nonce, :fetched_nonce]

  def start_link([]) do
    GenServer.start_link(__MODULE__, nil, name: __MODULE__, hibernate_after: 5_000)
  end

  @impl true
  def init(nil) do
    {:ok, %__MODULE__{}}
  end

  def nonce() do
    GenServer.call(__MODULE__, :nonce)
  end

  def peek_nonce() do
    GenServer.call(__MODULE__, :peek_nonce)
  end

  def check_stale_nonce() do
    send(__MODULE__, :check_stale_nonce)
  end

  @impl true
  def handle_call(:peek_nonce, _from, state = %NonceProvider{nonce: nonce}) do
    {:reply, nonce, state}
  end

  def handle_call(:nonce, _from, state = %NonceProvider{nonce: nil}) do
    nonce = fetch_nonce()
    {:reply, nonce, %NonceProvider{state | nonce: nonce + 1, fetched_nonce: nonce}}
  end

  def handle_call(:nonce, _from, state = %NonceProvider{nonce: nonce}) do
    # check if nonce is stale
    pid = self()
    Debouncer.apply(__MODULE__, fn -> send(pid, :check_stale_nonce) end, 30_000)

    {:reply, nonce, %NonceProvider{state | nonce: nonce + 1}}
  end

  @impl true
  def handle_info(
        :check_stale_nonce,
        state = %NonceProvider{nonce: old_nonce, fetched_nonce: fetched_once}
      ) do
    new_nonce = fetch_nonce()
    # if nonce is stuck then something is wrong with processing of transactions

    cond do
      new_nonce == fetched_once ->
        Logger.warn("Nonce is stuck (#{old_nonce}), resetting to: #{new_nonce}")
        {:noreply, %NonceProvider{state | fetched_nonce: new_nonce, nonce: new_nonce}}

      new_nonce > old_nonce ->
        Logger.warn("Nonce is too low (#{old_nonce}), resetting to: #{new_nonce}")
        {:noreply, %NonceProvider{state | fetched_nonce: new_nonce, nonce: new_nonce}}

      true ->
        {:noreply, %NonceProvider{state | fetched_nonce: new_nonce}}
    end
  end

  def fetch_nonce() do
    Moonbeam.get_transaction_count(
      Wallet.base16(CallPermit.wallet()),
      "latest"
    )
    |> Base16.decode_int()
  end
end

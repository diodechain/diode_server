defmodule RemoteChain.NonceProvider do
  use GenServer, restart: :permanent
  require Logger
  alias RemoteChain.NonceProvider

  defstruct [:nonce, :fetched_nonce, :chain]

  def start_link(chain) do
    GenServer.start_link(__MODULE__, chain, name: name(chain), hibernate_after: 5_000)
  end

  defp name(chain) do
    impl = RemoteChain.chainimpl(chain)
    {:global, {__MODULE__, impl}}
  end

  @impl true
  def init(chain) do
    {:ok, %__MODULE__{chain: chain}}
  end

  def nonce(chain) do
    GenServer.call(name(chain), :nonce)
  end

  @impl true
  def handle_call(:nonce, _from, state = %NonceProvider{nonce: nil, chain: chain}) do
    nonce = fetch_nonce(chain)
    {:reply, nonce, %NonceProvider{state | nonce: nonce + 1, fetched_nonce: nonce}}
  end

  def handle_call(:nonce, _from, state = %NonceProvider{chain: chain, nonce: nonce}) do
    Debouncer.apply(__MODULE__, fn -> GenServer.cast(name(chain), :check_stale_nonce) end, 30_000)
    {:reply, nonce, %NonceProvider{state | nonce: nonce + 1}}
  end

  @impl true
  def handle_cast(
        :check_stale_nonce,
        state = %NonceProvider{nonce: old_nonce, fetched_nonce: fetched_once, chain: chain}
      ) do
    new_nonce = fetch_nonce(chain)
    # if nonce is stuck then something is wrong with processing of transactions

    cond do
      new_nonce == fetched_once ->
        Logger.warning("RTX Nonce is stuck (#{old_nonce}), resetting to: #{new_nonce}")
        {:noreply, %NonceProvider{state | fetched_nonce: new_nonce, nonce: new_nonce}}

      new_nonce > old_nonce ->
        Logger.warning("RTX Nonce is too low (#{old_nonce}), resetting to: #{new_nonce}")
        {:noreply, %NonceProvider{state | fetched_nonce: new_nonce, nonce: new_nonce}}

      true ->
        {:noreply, %NonceProvider{state | fetched_nonce: new_nonce}}
    end
  end

  def handle_cast({:new_nonce, new_nonce}, state = %NonceProvider{nonce: old_nonce}) do
    if new_nonce > old_nonce do
      Logger.warning("RTX Nonce is too low (#{old_nonce}), resetting to: #{new_nonce}")
      {:noreply, %NonceProvider{state | nonce: new_nonce}}
    else
      {:noreply, state}
    end
  end

  def fetch_nonce(chain) do
    nonce =
      RemoteChain.RPCCache.get_transaction_count(
        chain,
        Wallet.base16(CallPermit.wallet()),
        "latest"
      )
      |> Base16.decode_int()

    GenServer.cast(name(chain), {:new_nonce, nonce})
    nonce
  end
end

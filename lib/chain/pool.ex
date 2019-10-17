defmodule Chain.Pool do
  alias Chain.Transaction
  use GenServer
  defstruct transactions: %{}

  @spec start_link(any()) :: :ignore | {:error, any()} | {:ok, pid()}
  def start_link(_opts) do
    GenServer.start_link(__MODULE__, :ok, name: __MODULE__)
  end

  @spec init(any()) :: {:ok, Chain.Pool.t()}
  def init(_init_arg) do
    {:ok, %Chain.Pool{}}
  end

  def remove_transaction(key) do
    remove_transactions([key])
  end

  def remove_transactions(%Chain.Block{} = block) do
    done = Chain.Block.transactions(block)
    keys = Enum.map(done, &Chain.Transaction.hash/1)
    remove_transactions(keys)
  end

  def remove_transactions(keys) do
    call(fn pool = %{transactions: transactions}, _from ->
      {:reply, :ok, %{pool | transactions: Map.drop(transactions, keys)}}
    end)

    Chain.Worker.update()
  end

  @spec add_transaction(Transaction.t()) :: :ok
  def add_transaction(%Transaction{} = tx) do
    key = Transaction.hash(tx)

    call(fn pool = %{transactions: transactions}, _from ->
      txs = Map.put(transactions, key, tx)
      {:reply, :ok, %{pool | transactions: txs}}
    end)

    Chain.Worker.update()
  end

  @spec flush() :: [Transaction.t()]
  def flush() do
    call(fn pool = %{transactions: transactions}, _from ->
      {:reply, Map.values(transactions), %{pool | transactions: %{}}}
    end)
  end

  @doc "Returns the optimal mining proposal"
  def proposal() do
    limit = Chain.gas_limit()
    avg = Chain.averagetransaction_gas()

    transactions()
    |> Enum.sort(fn a, b ->
      Transaction.gas_price(a) < Transaction.gas_price(b)
    end)
    |> Enum.take(floor(limit / avg * 1.2))
    |> Enum.sort(fn a, b -> Transaction.nonce(a) < Transaction.nonce(b) end)
  end

  @spec transactions() :: [Transaction.t()]
  def transactions() do
    call(fn pool = %{transactions: transactions}, _from ->
      {:reply, transactions, pool}
    end)
    |> Map.values()
  end

  defp call(fun, timeout \\ 5000) do
    GenServer.call(__MODULE__, fun, timeout)
  end

  def handle_call(fun, from, state) when is_function(fun) do
    fun.(state, from)
  end
end

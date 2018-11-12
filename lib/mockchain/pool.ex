defmodule Mockchain.Pool do
  alias Mockchain.Transaction
  use GenServer
  defstruct transactions: %{}

  @spec start_link(any()) :: :ignore | {:error, any()} | {:ok, pid()}
  def start_link(_opts) do
    GenServer.start_link(__MODULE__, :ok, name: __MODULE__)
  end

  @spec init(any()) :: {:ok, Mockchain.Pool.t()}
  def init(_init_arg) do
    {:ok, %Mockchain.Pool{}}
  end

  def remove_transaction(key) do
    remove_transactions([key])
  end

  def remove_transactions(keys) do
    call(fn pool = %{transactions: transactions}, _from ->
      {:reply, :ok, %{pool | transactions: Map.drop(transactions, keys)}}
    end)

    Mockchain.Worker.update()
  end

  @spec add_transaction(Transaction.t()) :: :ok
  def add_transaction(%Transaction{} = tx) do
    key = Transaction.hash(tx)

    call(fn pool = %{transactions: transactions}, _from ->
      txs = Map.put(transactions, key, tx)
      {:reply, :ok, %{pool | transactions: txs}}
    end)

    Mockchain.Worker.update()
  end

  @spec flush() :: [Transaction.t()]
  def flush() do
    call(fn pool = %{transactions: transactions}, _from ->
      {:reply, Map.values(transactions), %{pool | transactions: %{}}}
    end)
  end

  @doc "Returns the optimal mining proposal"
  def proposal() do
    limit = Mockchain.gasLimit()
    avg = Mockchain.averageTransactionGas()

    transactions()
    |> Enum.sort(fn a, b ->
      Transaction.gasPrice(a) < Transaction.gasPrice(b)
    end)
    |> Enum.take(floor(limit / avg * 1.2))
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

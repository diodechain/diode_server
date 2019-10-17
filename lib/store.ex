defmodule Store do
  alias Chain.BlockCache, as: Block
  alias Chain.Transaction

  use GenServer
  require Logger

  require Record
  Record.defrecord(:keyValue, key: nil, value: nil)

  @spec start_link(any()) :: :ignore | {:error, any()} | {:ok, pid()}
  def start_link(_opts) do
    GenServer.start_link(__MODULE__, :ok, name: __MODULE__)
  end

  @spec init(:ok) :: {:ok, %{}}
  def init(:ok) do
    Application.start(:sasl)
    dir = Diode.data_dir()

    Application.put_env(:mnesia, :dir, :binary.bin_to_list(dir))

    case :mnesia.create_schema([node()]) do
      :ok -> :ok
      {:error, {_, {:already_exists, _}}} -> :ok
    end

    Application.ensure_all_started(:mnesia)
    create_table!(:keyValue, Keyword.keys(keyValue(keyValue())))

    ensure_identity()
    IO.puts("==== Mining Node ====")
    IO.puts("#{Wallet.printable(Store.wallet())}")
    IO.puts("")

    KademliaStore.init()
    TicketStore.init()
    # Chain.blocks(1000)
    # KBuckets.init()

    create_table!(:aliases, [:alias, :object_id])
    create_table!(:transactions, [:hash, :tx_struct, :block])

    case Diode.get_env_int("PRIVATE", 0) do
      # Decode env parameter such as
      # export PRIVATE="0x123456789"
      0 ->
        :ok

      private ->
        :binary.encode_unsigned(private)
        |> Wallet.from_privkey()
        |> set_wallet()
    end

    {:ok, %{}}
  end

  defp ensure_identity() do
    record =
      read_one(:keyValue, :identity, fn ->
        id = Secp256k1.generate()
        record = keyValue(key: :identity, value: id)
        :ok = :mnesia.write(record)
        record
      end)

    keyValue(record, :value)
  end

  def set_wallet(wallet) do
    id = {Wallet.pubkey!(wallet), Wallet.privkey!(wallet)}
    record = keyValue(key: :identity, value: id)
    write_one(record)
  end

  defp read_one(table, key, default) do
    {:atomic, record} =
      :mnesia.transaction(fn ->
        case :mnesia.read(table, key) do
          [] ->
            case default do
              fun when is_function(fun) -> fun.()
              value -> value
            end

          [record] ->
            record
        end
      end)

    record
  end

  defp write_one(record) do
    :mnesia.transaction(fn ->
      :ok = :mnesia.write(record)
    end)
  end

  def wallet() do
    {_public, private} = ensure_identity()
    Wallet.from_privkey(private)
  end

  def get_network_for_device(device_id) do
    device_id
  end

  def create_table!(table, attributes, props \\ []) do
    props =
      case props do
        [] ->
          [
            {:disc_copies, [node()]},
            {:local_content, true},
            {:attributes, attributes},
            # {:index, [1]},
            {:storage_properties, [{:ets, [:compressed]}, {:dets, [{:auto_save, 5000}]}]}
          ]

        _ ->
          [{:attributes, attributes} | props]
      end

    case :mnesia.create_table(table, props) do
      {:atomic, :ok} -> :ok
      {:aborted, {:already_exists, _}} -> :ok
    end

    :ok = :mnesia.wait_for_tables([table], 10000)
  end

  def handle_info({:nodeup, node}, state) do
    Logger.warn("Node #{inspect(node)} UP")
    {:noreply, state}
  end

  def handle_info({:nodedown, node}, state) do
    Logger.warn("Node #{inspect(node)} DOWN")
    {:noreply, state}
  end

  @spec transaction(any()) :: any()
  def transaction(hash) do
    case read_one(:transactions, hash, nil) do
      {:transactions, ^hash, tx, _block} -> tx
      nil -> nil
    end
  end

  def transaction_block(hash) do
    case read_one(:transactions, hash, nil) do
      {:transactions, ^hash, _tx, block} -> block
      nil -> nil
    end
  end

  @spec set_transaction(Chain.Transaction.t(), <<_::256>>) ::
          {:aborted, any()} | {:atomic, any()}
  def set_transaction(tx = %Transaction{}, block_hash = <<_::256>>) do
    write_one({:transactions, Transaction.hash(tx), tx, block_hash})
  end

  def clear_transactions() do
    :mnesia.clear_table(:transactions)
  end

  @spec set_block_transactions(Chain.Block.t()) :: :ok
  def set_block_transactions(block = %Chain.Block{}) do
    for tx <- block.transactions do
      set_transaction(tx, Block.hash(block))
      # :io.format("~p~n", [Transaction.hash(tx)])
    end

    :ok
  end

  def seed_transactions() do
    Chain.blocks()
    |> seed_transactions()
  end

  def seed_transactions(blocks) do
    clear_transactions()

    :mnesia.transaction(fn ->
      for block <- blocks, do: set_block_transactions(block)
    end)

    :ok
  end
end

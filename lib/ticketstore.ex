defmodule TicketStore do
  alias Object.Ticket, as: Ticket
  import Ticket

  @spec init() :: :ok
  def init() do
    Store.create_table!(:tickets, [:ticket_id, :ticket])
  end

  def clear() do
    :mnesia.delete_table(:tickets)
    init()
  end

  @doc """
    Handling a ConnectionTicket
  """
  @spec add(Ticket.t()) :: {:ok, non_neg_integer()} | {:too_low, Ticket.t()}
  def add(ticket() = tck) do
    id = :erlang.phash2({:tck, Ticket.device_address(tck), Ticket.fleet_contract(tck)})

    case find(id) do
      nil ->
        write(id, tck)
        {:ok, 0}

      last ->
        if Ticket.total_connections(last) < Ticket.total_connections(tck) or
             Ticket.total_bytes(last) < Ticket.total_bytes(tck) do
          write(id, tck)
          {:ok, max(0, Ticket.total_bytes(tck) - Ticket.total_bytes(last))}
        else
          {:too_low, last}
        end
    end
  end

  def find(device = <<_::160>>, fleet = <<__::160>>) do
    :erlang.phash2({:tck, device, fleet})
    |> find()
  end

  defp find(key) do
    {:atomic, value} =
      :mnesia.transaction(fn ->
        case :mnesia.read(:tickets, key) do
          [] -> nil
          [{:tickets, ^key, value}] -> value
        end
      end)

    value
  end

  defp write(key, ticket) do
    {:atomic, :ok} =
      :mnesia.transaction(fn ->
        :mnesia.write({:tickets, key, ticket})
      end)

    :ok
  end
end

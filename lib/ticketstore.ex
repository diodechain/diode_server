# Diode Server
# Copyright 2019 IoT Blockchain Technology Corporation LLC (IBTC)
# Licensed under the Diode License, Version 1.0
defmodule TicketStore do
  alias Object.Ticket, as: Ticket
  alias Chain.BlockCache, as: Block
  import Ticket

  @spec init() :: :ok
  def init() do
    Store.create_table!(:tickets, [:ticket_id, :epoch, :ticket])
  end

  def clear() do
    {:atomic, :ok} = :mnesia.clear_table(:tickets)
  end

  def tickets(epoch) do
    :mnesia.dirty_select(:tickets, [
      {{:tickets, :_, :"$2", :"$3"}, [{:==, :"$2", epoch}], [:"$3"]}
    ])
  end

  # Should be called on each new block
  def newblock() do
    peak = Chain.peakBlock()
    epoch = Block.epoch(peak)
    last = Block.parent(peak)

    # Cleaning table
    if epoch != Block.epoch(last) do
      {:atomic, _} =
        :mnesia.transaction(fn ->
          # Deleting all tickets for Epochs older than current - 1
          :mnesia.select(:tickets, [
            {{:tickets, :"$1", :"$2", :_}, [{:<, :"$2", epoch - 1}], [:"$1"]}
          ])
          |> Enum.map(fn key -> :mnesia.delete({:tickets, key}) end)
        end)
    end

    # Submitting traffic tickets not too late
    height = Block.number(peak)

    if rem(height, Chain.epoch_length()) > Chain.epoch_length() / 2 do
      tickets = tickets(epoch - 1)

      if length(tickets) > 0 do
        tickets
        |> Enum.map(fn tck -> Ticket.raw(tck) end)
        |> List.flatten()
        |> Contract.Registry.submitTicketRawTx()
        |> Chain.Pool.add_transaction(true)

        tickets
        |> Enum.map(fn tck ->
          :mnesia.delete(
            {:tickets, key(Ticket.device_address(tck), Ticket.fleet_contract(tck), epoch - 1)}
          )
        end)
      end
    end
  end

  @doc """
    Handling a ConnectionTicket
  """
  @spec add(Ticket.t()) ::
          {:ok, non_neg_integer()} | {:too_low, Ticket.t()} | {:too_old, integer()}
  def add(ticket() = tck) do
    tepoch = Ticket.epoch(tck)
    epoch = Chain.epoch()

    if epoch - 1 < tepoch do
      key = key(Ticket.device_address(tck), Ticket.fleet_contract(tck), tepoch)

      case find(key) do
        nil ->
          write(key, tck)
          {:ok, Ticket.total_bytes(tck)}

        last ->
          if Ticket.total_connections(last) < Ticket.total_connections(tck) or
               Ticket.total_bytes(last) < Ticket.total_bytes(tck) do
            write(key, tck)
            {:ok, max(0, Ticket.total_bytes(tck) - Ticket.total_bytes(last))}
          else
            {:too_low, last}
          end
      end
    else
      {:too_old, epoch - 1}
    end
  end

  @spec find(<<_::160>>, <<_::160>>, integer) :: any
  def find(device, fleet, epoch) do
    find(key(device, fleet, epoch))
  end

  defp key(device = <<_::160>>, fleet = <<__::160>>, epoch) when is_integer(epoch) do
    :erlang.phash2({:tck, device, fleet, epoch})
  end

  defp find(key) do
    {:atomic, value} =
      :mnesia.transaction(fn ->
        case :mnesia.read(:tickets, key) do
          [] -> nil
          [{_, ^key, _epoch, value}] -> value
        end
      end)

    value
  end

  defp write(key, ticket) do
    {:atomic, :ok} =
      :mnesia.transaction(fn ->
        :mnesia.write({:tickets, key, Ticket.epoch(ticket), ticket})
      end)

    :ok
  end
end

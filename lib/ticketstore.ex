# Diode Server
# Copyright 2019 IoT Blockchain Technology Corporation LLC (IBTC)
# Licensed under the Diode License, Version 1.0
defmodule TicketStore do
  alias Object.Ticket
  alias Chain.BlockCache, as: Block
  alias Model.TicketSql
  import Ticket

  def clear() do
    TicketSql.delete_all()
  end

  def tickets(epoch) do
    TicketSql.tickets(epoch)
  end

  # Should be called on each new block
  def newblock(peak) do
    epoch = Block.epoch(peak)
    last = Block.parent(peak)

    # Cleaning table
    if epoch != Block.epoch(last) do
      TicketSql.delete_old(epoch - 1)
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

        Enum.map(tickets, fn tck -> TicketSql.delete(tck) end)
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
      last = find(Ticket.device_address(tck), Ticket.fleet_contract(tck), tepoch)

      case last do
        nil ->
          TicketSql.put_ticket(tck)
          {:ok, Ticket.total_bytes(tck)}

        last ->
          if Ticket.total_connections(last) < Ticket.total_connections(tck) or
               Ticket.total_bytes(last) < Ticket.total_bytes(tck) do
            TicketSql.put_ticket(tck)
            {:ok, max(0, Ticket.total_bytes(tck) - Ticket.total_bytes(last))}
          else
            if Ticket.device_address(tck) != Ticket.device_address(last) do
              :io.format("Ticked Signed on Fork Chain~n")
              :io.format("Last: ~180p~nTick: ~180p~n", [last, tck])
              TicketSql.put_ticket(tck)
              {:ok, Ticket.total_bytes(tck)}
            else
              {:too_low, last}
            end
          end
      end
    else
      {:too_old, epoch - 1}
    end
  end

  def find(device = <<_::160>>, fleet = <<__::160>>, epoch) when is_integer(epoch) do
    TicketSql.find(device, fleet, epoch)
  end
end

# Diode Server
# Copyright 2019 IoT Blockchain Technology Corporation LLC (IBTC)
# Licensed under the Diode License, Version 1.0
defmodule TicketStore do
  alias Object.Ticket
  alias Chain.BlockCache, as: Block
  alias Model.TicketSql
  alias Model.Ets
  use GenServer
  import Ticket

  def start_link(ets_extra) do
    GenServer.start_link(__MODULE__, ets_extra, name: __MODULE__)
  end

  def init(ets_extra) do
    Ets.init(__MODULE__, ets_extra)
    {:ok, nil}
  end

  def clear() do
    TicketSql.delete_all()
  end

  def tickets(epoch) do
    TicketSql.tickets(epoch)
  end

  # Should be called on each new block
  def newblock(peak) do
    epoch = Block.epoch(peak)

    # Submitting traffic tickets not too late
    height = Block.number(peak)

    if not Diode.dev_mode?() and rem(height, Chain.epoch_length()) > Chain.epoch_length() / 2 do
      submit_tickets(epoch - 1)
    end
  end

  def submit_tickets(epoch) do
    tickets = tickets(epoch)

    if length(tickets) > 0 do
      tx =
        tickets
        |> Enum.filter(fn tck ->
          Ticket.raw(tck)
          |> Contract.Registry.submit_ticket_raw_tx()
          |> Shell.call_tx("latest")
          |> case do
            {"", _gas_cost} ->
              true

            {{:evmc_revert, reason}, _} ->
              :io.format("TicketStore:submit_tickets(~p) ticket error: ~p~n", [epoch, reason])
              false

            other ->
              :io.format("TicketStore:submit_tickets(~p) ticket error: ~p~n", [epoch, other])
              false
          end
        end)
        |> Enum.map(fn tck -> Ticket.raw(tck) end)
        |> List.flatten()
        |> Contract.Registry.submit_ticket_raw_tx()

      case Shell.call_tx(tx, "latest") do
        {"", _gas_cost} ->
          Chain.Pool.add_transaction(tx, true)

        {{:evmc_revert, reason}, _} ->
          :io.format("TicketStore:submit_tickets(~p) transaction error: ~p~n", [epoch, reason])

        other ->
          :io.format("TicketStore:submit_tickets(~p) transaction error: ~p~n", [epoch, other])
      end
    end
  end

  @doc """
    Handling a ConnectionTicket
  """
  @spec add(Ticket.t(), Wallet.t()) ::
          {:ok, non_neg_integer()} | {:too_low, Ticket.t()} | {:too_old, integer()}
  def add(ticket() = tck, wallet) do
    tepoch = Ticket.epoch(tck)
    epoch = Chain.epoch()
    address = Wallet.address!(wallet)
    fleet = Ticket.fleet_contract(tck)

    if epoch - 1 < tepoch do
      last = find(address, fleet, tepoch)

      case last do
        nil ->
          put_ticket(tck, address, fleet, tepoch)
          {:ok, Ticket.total_bytes(tck)}

        last ->
          if Ticket.total_connections(last) < Ticket.total_connections(tck) or
               Ticket.total_bytes(last) < Ticket.total_bytes(tck) do
            put_ticket(tck, address, fleet, tepoch)
            {:ok, max(0, Ticket.total_bytes(tck) - Ticket.total_bytes(last))}
          else
            if address != Ticket.device_address(last) do
              :io.format("Ticked Signed on Fork Chain~n")
              :io.format("Last: ~180p~nTick: ~180p~n", [last, tck])
              put_ticket(tck, address, fleet, tepoch)
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

  defp put_ticket(tck, device = <<_::160>>, fleet = <<__::160>>, epoch) when is_integer(epoch) do
    key = {device, fleet, epoch}

    Debouncer.delay(key, fn ->
      TicketSql.put_ticket(tck)
      Ets.remove(__MODULE__, key)
    end)

    Ets.put(__MODULE__, key, tck)
  end

  def find(device = <<_::160>>, fleet = <<__::160>>, epoch) when is_integer(epoch) do
    Ets.lookup(__MODULE__, {device, fleet, epoch}, fn ->
      TicketSql.find(device, fleet, epoch)
    end)
  end

  def count(epoch) do
    TicketSql.count(epoch)
  end

  @doc "Reports ticket value in 1024 blocks"
  def value(epoch) do
    Enum.reduce(tickets(epoch), 0, fn tck, acc ->
      div(Ticket.total_bytes(tck) + Ticket.total_connections(tck) * 1024, 1024) + acc
    end)
  end
end

# Diode Server
# Copyright 2021 Diode
# Licensed under the Diode License, Version 1.1
defmodule TicketStore do
  alias Object.Ticket
  alias Chain.BlockCache, as: Block
  alias Model.TicketSql
  alias Model.Ets
  use GenServer
  import Ticket

  @ticket_value_cache :ticket_value_cache

  def start_link(ets_extra) do
    GenServer.start_link(__MODULE__, ets_extra, name: __MODULE__)
  end

  def init(ets_extra) do
    Ets.init(__MODULE__, ets_extra)
    EtsLru.new(@ticket_value_cache, 1024)
    {:ok, nil}
  end

  def clear() do
    TicketSql.delete_all()
  end

  def tickets(epoch) do
    Ets.all(__MODULE__)
    |> Enum.filter(fn tck -> Ticket.epoch(tck) == epoch end)
    |> Enum.concat(TicketSql.tickets(epoch))
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
    tickets =
      tickets(epoch)
      |> Enum.filter(fn tck ->
        estimate_ticket_value(tck, epoch) > 1_000_000
      end)
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

    if length(tickets) > 0 do
      tx =
        Enum.flat_map(tickets, fn tck ->
          store_ticket_value(tck, epoch)
          Ticket.raw(tck)
        end)
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

  defp put_ticket(tck, device = <<_::160>>, fleet = <<_f::160>>, epoch) when is_integer(epoch) do
    key = {device, fleet, epoch}

    Debouncer.delay(key, fn ->
      TicketSql.put_ticket(tck)
      Ets.remove(__MODULE__, key)
    end)

    Ets.put(__MODULE__, key, tck)
  end

  def find(device = <<_::160>>, fleet = <<_f::160>>, epoch) when is_integer(epoch) do
    Ets.lookup(__MODULE__, {device, fleet, epoch}, fn ->
      TicketSql.find(device, fleet, epoch)
    end)
  end

  def count(epoch) do
    TicketSql.count(epoch)
  end

  def estimate_ticket_value(tck, epoch) do
    device = Ticket.device_address(tck)
    fleet = Ticket.fleet_contract(tck)

    fleet_value =
      EtsLru.fetch(@ticket_value_cache, {:fleet, fleet, epoch}, fn ->
        Contract.Registry.fleet_value(0, fleet, Chain.epoch_length() * epoch)
      end)

    ticket_value = value(tck) * fleet_value

    case EtsLru.get(@ticket_value_cache, {:ticket, fleet, device, epoch}) do
      nil -> ticket_value
      prev -> ticket_value - prev
    end
  end

  def store_ticket_value(tck, epoch) do
    device = Ticket.device_address(tck)
    fleet = Ticket.fleet_contract(tck)

    fleet_value =
      EtsLru.fetch(@ticket_value_cache, {:fleet, fleet, epoch}, fn ->
        Contract.Registry.fleet_value(0, fleet, Chain.epoch_length() * epoch)
      end)

    ticket_value = value(tck) * fleet_value

    case EtsLru.get(@ticket_value_cache, {:ticket, fleet, device, epoch}) do
      prev when prev >= ticket_value -> prev
      _other -> EtsLru.put(@ticket_value_cache, {:ticket, fleet, device, epoch}, ticket_value)
    end
  end

  @doc "Reports ticket value in 1024 blocks"
  def value(ticket() = tck) do
    div(Ticket.total_bytes(tck) + Ticket.total_connections(tck) * 1024, 1024)
  end

  def value(epoch) when is_integer(epoch) do
    Enum.reduce(tickets(epoch), 0, fn tck, acc -> value(tck) + acc end)
  end
end

# Diode Server
# Copyright 2021-2024 Diode
# Licensed under the Diode License, Version 1.1
defmodule Network.Channel do
  import Object.Channel, only: :macros
  use GenServer

  alias Network.EdgeV2.Port
  alias Network.EdgeV2.PortClient
  alias Network.EdgeV2.PortCollection

  def start_link(ch = channel()) do
    GenServer.start_link(__MODULE__, ch, hibernate_after: 5_000)
  end

  def init(ch) do
    state = %{
      ports: %PortCollection{},
      pid: self(),
      channel: ch
    }

    {:ok, state}
  end

  def handle_call({:portopen, this, ref, flags, portname, _device_address}, from, state) do
    case PortCollection.get(state.ports, ref) do
      nil ->
        mon = Process.monitor(this)

        client = %PortClient{
          mon: mon,
          pid: this,
          ref: ref,
          write: String.contains?(flags, "r")
        }

        port = %Port{
          state: :open,
          from: from,
          clients: [client],
          portname: portname,
          shared: true,
          ref: ref
        }

        case PortCollection.find_sharedport(state.ports, port) do
          nil ->
            ports = PortCollection.put(state.ports, port)

            {:reply, {:ok, port.ref}, %{state | ports: ports},
             {:continue, {:new_client, port.ref}}}

          existing_port ->
            port = %Port{existing_port | clients: [client | existing_port.clients]}
            ports = PortCollection.put(state.ports, port)

            {:reply, {:ok, existing_port.ref}, %{state | ports: ports},
             {:continue, {:new_client, port.ref}}}
        end

      _other ->
        {:reply, {:error, "already opening"}, state}
    end
  end

  def handle_continue({:new_client, ref}, state = %{ports: ports}) do
    port = %Port{mailbox: mailbox, clients: clients} = PortCollection.get(state.ports, ref)

    cond do
      :queue.is_empty(mailbox) ->
        {:noreply, state}

      not Enum.any?(clients, fn %{write: write} -> write end) ->
        {:noreply, state}

      true ->
        list = :queue.to_list(mailbox)

        for client <- clients do
          if client.write do
            for data <- list do
              GenServer.cast(client.pid, {:portsend, client.ref, data, self()})
            end
          end
        end

        port = %{port | mailbox: :queue.new()}
        ports = PortCollection.put(ports, port)
        {:noreply, %{state | ports: ports}}
    end
  end

  def handle_cast({:portsend, ref, data, from_pid}, state) do
    state =
      case PortCollection.get(state.ports, ref) do
        nil ->
          state

        port = %Port{state: :open, clients: clients, mailbox: mailbox} ->
          for client <- clients do
            if client.write and client.pid != from_pid do
              GenServer.cast(client.pid, {:portsend, client.ref, data, state.pid})
              true
            else
              false
            end
          end
          |> Enum.any?()
          |> if do
            # Message has been sent to at least one peer
            state
          else
            case state.channel do
              channel(type: "mailbox") ->
                port = %{port | mailbox: :queue.in(data, mailbox)}
                %{state | ports: PortCollection.put(state.ports, port)}

              _ ->
                state
            end
          end
      end

    {:noreply, state}
  end

  def handle_cast({:portclose, ref}, state) do
    {:noreply, portclose(state, ref)}
  end

  def handle_info({:DOWN, monitor, :process, _pid, _reason}, state) do
    {:noreply, portclose(state, monitor)}
  end

  # Removing client but keeping port open if still >0 clients
  defp portclose(state, clientmon) when is_reference(clientmon) do
    do_portclose(state, PortCollection.get_clientmon(state.ports, clientmon))
  end

  defp portclose(state, clientref) do
    do_portclose(state, PortCollection.get_clientref(state.ports, clientref))
  end

  defp do_portclose(state = %{ports: ports}, {client, port}) do
    Process.demonitor(client.mon, [:flush])

    ports =
      if port.clients == [] and :queue.is_empty(port.mailbox) do
        PortCollection.delete(ports, port.ref)
      else
        PortCollection.put(ports, %Port{port | clients: List.delete(port.clients, client)})
      end

    %{state | ports: ports}
  end
end

defmodule Network.EdgeHandler do
  use Network.Handler
  alias Object.Ticket, as: Ticket
  import Ticket

  defmodule PortClient do
    defstruct pid: nil, mon: nil, socket: nil, ref: nil, write: true

    @type t :: %PortClient{
            pid: pid(),
            mon: reference(),
            socket: pid(),
            write: true | false
          }
  end

  defmodule Port do
    defstruct state: nil,
              ref: nil,
              from: nil,
              clients: [],
              portname: nil,
              shared: false

    @type t :: %Port{
            state: :open | :pre_open,
            ref: reference(),
            from: nil | {pid(), reference()},
            clients: [PortClient.t()],
            portname: any(),
            shared: true | false
          }
  end

  @moduledoc """
    There are currently three access rights for "Ports" which are
    loosely following Posix conventions:
      1) r = Read
      2) w = Write
      3) s = Shared
  """
  defmodule PortCollection do
    defstruct refs: %{}
    @type t :: %PortCollection{refs: %{reference() => Port.t()}}

    @spec put(PortCollection.t(), Port.t()) :: PortCollection.t()
    def put(pc, port) do
      %{pc | refs: Map.put(pc.refs, port.ref, port)}
    end

    @spec delete(PortCollection.t(), reference()) :: PortCollection.t()
    def delete(pc, ref) do
      %{pc | refs: Map.delete(pc.refs, ref)}
    end

    @spec get(PortCollection.t(), reference(), any()) :: Port.t() | nil
    def get(pc, ref, default \\ nil) do
      Map.get(pc.refs, ref, default)
    end

    @spec get_clientref(PortCollection.t(), reference()) :: {PortClient.t(), Port.t()} | nil
    def get_clientref(pc, cref) do
      Enum.find_value(pc.refs, fn {_ref, port} ->
        Enum.find_value(port.clients, fn
          client = %PortClient{ref: ^cref} -> {client, port}
          _ -> nil
        end)
      end)
    end

    @spec get_clientmon(PortCollection.t(), reference()) :: {PortClient.t(), Port.t()} | nil
    def get_clientmon(pc, cmon) do
      Enum.find_value(pc.refs, fn {_ref, port} ->
        Enum.find_value(port.clients, fn
          client = %PortClient{mon: ^cmon} -> {client, port}
          _ -> nil
        end)
      end)
    end

    @spec find_sharedport(PortCollection.t(), Port.t()) :: Port.t() | nil
    def find_sharedport(_pc, %Port{shared: false}) do
      nil
    end

    def find_sharedport(pc, %Port{portname: portname}) do
      Enum.find_value(pc.refs, fn
        {_ref, port = %Port{state: :open, portname: ^portname, shared: true}} -> port
        {_ref, _other} -> nil
      end)
    end
  end

  @type state :: %{
          socket: any(),
          node_id: Wallet.t(),
          peer: tuple(),
          ports: PortCollection.t(),
          unpaid_bytes: integer()
        }

  def do_init(state) do
    {:ok, peer} = :ssl.peername(state.socket)
    PubSub.subscribe({:edge, Wallet.address!(state.node_id)})
    :io.format("Edgehandler:init #{Wallet.printable(state.node_id)} from ~200p~n", [peer])

    state =
      Map.merge(state, %{
        peer: peer,
        ports: %PortCollection{},
        unpaid_bytes: 0
      })

    {:noreply, state}
  end

  def ssl_options() do
    Network.Server.default_ssl_options()
  end

  def handle_call(fun, from, state) when is_function(fun) do
    fun.(from, state)
  end

  def handle_cast(fun, state) when is_function(fun) do
    fun.(state)
  end

  def handle_info({:ssl, _socket, msg}, state) do
    state = account_incoming(state, msg)
    msg = decode(msg)

    case msg do
      [
        "ticket",
        block,
        fleet_contract,
        total_connections,
        total_bytes,
        local_address,
        device_signature
      ] ->
        dl =
          ticket(
            server_id: Wallet.address!(Store.wallet()),
            fleet_contract: fleet_contract,
            total_connections: total_connections,
            total_bytes: total_bytes,
            local_address: local_address,
            block_number: block,
            device_signature: device_signature
          )

        state =
          if Ticket.device_verify(dl, nodeid(state)) do
            case TicketStore.add(dl) do
              {:ok, bytes} ->
                dl = Ticket.server_sign(dl, Wallet.privkey!(Store.wallet()))
                Kademlia.store(Object.key(dl), Object.encode!(dl))
                state = %{state | unpaid_bytes: state.unpaid_bytes - bytes}
                send!(state, ["response", "ticket", "thanks!"])

              {:too_old, min} ->
                send!(state, [
                  "response",
                  "ticket",
                  "too_old",
                  min
                ])

              {:too_low, last} ->
                send!(state, [
                  "response",
                  "ticket",
                  "too_low",
                  Ticket.block_hash(last),
                  Ticket.total_connections(last),
                  Ticket.total_bytes(last),
                  Ticket.local_address(last),
                  Ticket.device_signature(last)
                ])
            end
          else
            send!(state, ["error", "ticket", "signature mismatch"])
          end

        {:noreply, state}

      ["ping"] ->
        state = send!(state, ["response", "ping", "pong"])
        {:noreply, state}

      ["getobject", key] ->
        value =
          case Kademlia.find_value(key) do
            nil -> nil
            binary -> Object.encode_list!(Object.decode!(binary))
          end

        state = send!(state, ["response", "getobject", value])
        {:noreply, state}

      ["getnode", node] ->
        ret =
          case Kademlia.find_node(node) do
            nil -> nil
            item -> Object.encode_list!(KBuckets.object(item))
          end

        state = send!(state, ["response", "getnode", ret])
        {:noreply, state}

      ["getblockpeak"] ->
        state = send!(state, ["response", "getblockpeak", Chain.peak()])
        {:noreply, state}

      ["getblock", index] when is_integer(index) ->
        state = send!(state, ["response", "getblock", Chain.block(index)])
        {:noreply, state}

      ["getblockheader", index] when is_integer(index) ->
        state = send!(state, ["response", "getblockheader", Chain.block(index).header])
        {:noreply, state}

      ["getstateroots", index] ->
        merkel = Chain.state(index).store
        state = send!(state, ["response", "getstateroots", MerkleTree.root_hashes(merkel)])
        {:noreply, state}

      ["getaccount", index, id] ->
        mstate = Chain.state(index)

        state =
          case Chain.State.account(mstate, id) do
            nil ->
              send!(state, ["error", "getaccount", "account does not exist"])

            account = %Chain.Account{} ->
              proof = MerkleTree.get_proofs(mstate.store, id)

              send!(state, [
                "response",
                "getaccount",
                %{
                  nonce: account.nonce,
                  balance: account.balance,
                  storageRoot: MerkleTree.root_hash(account.storageRoot),
                  code: Chain.Account.codehash(account)
                },
                proof
              ])
          end

        {:noreply, state}

      ["getaccountroots", index, id] ->
        mstate = Chain.state(index)

        state =
          case Chain.State.account(mstate, id) do
            nil ->
              send!(state, ["error", "getaccountroots", "account does not exist"])

            %Chain.Account{storageRoot: storageRoot} ->
              send!(state, [
                "response",
                "getaccountroots",
                MerkleTree.root_hashes(storageRoot)
              ])
          end

        {:noreply, state}

      ["getaccountvalue", index, id, key] ->
        mstate = Chain.state(index)

        state =
          case Chain.State.account(mstate, id) do
            nil ->
              send!(state, ["error", "getaccountvalue", "account does not exist"])

            %Chain.Account{storageRoot: storageRoot} ->
              send!(state, [
                "response",
                "getaccountvalue",
                MerkleTree.get_proofs(storageRoot, key)
              ])
          end

        {:noreply, state}

      ["portopen", device_id, port, flags] ->
        portopen(state, device_id, port, flags)

      ["portopen", device_id, port] ->
        portopen(state, device_id, port)

      ["response", "portopen", ref, "ok"] ->
        port = %Port{state: :pre_open} = PortCollection.get(state.ports, ref)
        GenServer.reply(port.from, {:ok, state.socket, ref})
        ports = PortCollection.put(state.ports, %Port{port | state: :open, from: nil})
        {:noreply, %{state | ports: ports}}

      ["error", "portopen", ref, reason] ->
        port = %Port{state: :pre_open} = PortCollection.get(state.ports, ref)
        GenServer.reply(port.from, {:error, reason})
        {:noreply, portclose(state, port, false)}

      ["portsend", ref, data] ->
        case PortCollection.get(state.ports, ref) do
          nil ->
            state = send!(state, ["error", "portsend", "port does not exist"])
            {:noreply, state}

          %Port{state: :open, clients: clients} ->
            for client <- clients do
              if client.write do
                GenServer.cast(client.pid, fn cstate ->
                  {:noreply, send!(cstate, ["portsend", client.ref, data])}
                end)
              end
            end

            state = send!(state, ["response", "portsend", "ok"])
            {:noreply, state}
        end

      ["portclose", ref] ->
        case PortCollection.get(state.ports, ref) do
          nil ->
            state = send!(state, ["error", "portsend", "port does not exit"])
            {:noreply, state}

          port = %Port{state: :open} ->
            state = send!(state, ["response", "portclose", "ok"])
            {:noreply, portclose(state, port, false)}
        end

      nil ->
        state = send!(state, ["error", 400, "that is not json"])
        :io.format("~p:Unhandled message: ~p~n", [__MODULE__, truncate(msg)])
        {:noreply, state}

      _ ->
        state = send!(state, ["error", 401, "bad input"])
        :io.format("~p:Unhandled message: ~40s~n", [__MODULE__, truncate(msg)])
        {:noreply, state}
    end
  end

  def handle_info({:topic, topic, message}, state) do
    state = send!(state, [topic, message])
    {:noreply, state}
  end

  def handle_info(:stop_unpaid, state = %{unpaid_bytes: b}) do
    :io.format(
      "Edgehandler connection to #{Wallet.printable(state.node_id)} closed because unpaid #{b} bytes.~n"
    )

    send!(state, ["goodbye", "ticket expected", "you might get blacklisted"])
    {:stop, :normal, state}
  end

  def handle_info({:ssl_closed, _}, state) do
    :io.format("Edgehandler connection to #{Wallet.printable(state.node_id)} closed by remote.~n")
    {:stop, :normal, state}
  end

  def handle_info({:DOWN, mon, _type, _object, _info}, state) do
    {:noreply, portclose(state, mon)}
  end

  def handle_info(msg, state) do
    :io.format("~p handle_info: ~p ~p~n", [__MODULE__, msg, state])
    {:noreply, state}
  end

  defp truncate(msg) when is_binary(msg) and byte_size(msg) > 40 do
    binary_part(msg, 0, 37) <> "..."
  end

  defp truncate(msg) when is_binary(msg) do
    msg
  end

  defp truncate(other) do
    :io_lib.format("~0p", [other])
    |> :erlang.iolist_to_binary()
    |> truncate()
  end

  defp portopen(state, device_id, portname, flags \\ "rw") do
    cond do
      device_id == Wallet.address!(state.node_id) ->
        state = send!(state, ["error", "portopen", "can't connect to yourself"])
        {:noreply, state}

      validate_flags(flags) == false ->
        state = send!(state, ["error", "portopen", "invalid flags"])
        {:noreply, state}

      true ->
        with <<bin::binary-size(20)>> <- device_id,
             w <- Wallet.from_address(bin),
             [pid] <- PubSub.subscribers({:edge, Wallet.address!(w)}) do
          do_portopen(state, portname, flags, pid)
        else
          [] ->
            state = send!(state, ["error", "portopen", "not found"])
            {:noreply, state}

          _other ->
            state = send!(state, ["error", "portopen", "invalid address"])
            {:noreply, state}
        end
    end
  end

  defp validate_flags("rw"), do: true
  defp validate_flags("r"), do: true
  defp validate_flags("w"), do: true
  defp validate_flags("rws"), do: true
  defp validate_flags("rs"), do: true
  defp validate_flags("ws"), do: true
  defp validate_flags(_), do: false

  defp do_portopen(state, portname, flags, pid) do
    socket = state.socket

    mon = Process.monitor(pid)
    ref = :erlang.phash(mon, 0xFFFF)
    spid = self()

    #  Receives an open request from another local connected edge worker.
    #  Now needs to forward the request to the device and remember to
    #  keep in 'pre-open' state until the device acks.
    # Todo: Check for network access based on contract
    resp =
      try do
        GenServer.call(pid, fn from, state2 ->
          case PortCollection.get(state2.ports, ref) do
            nil ->
              mon = Process.monitor(spid)

              client = %PortClient{
                mon: mon,
                pid: spid,
                socket: socket,
                ref: ref,
                write: String.contains?(flags, "r")
              }

              port = %Port{
                state: :pre_open,
                from: from,
                clients: [client],
                portname: portname,
                shared: String.contains?(flags, "s"),
                ref: ref
              }

              case PortCollection.find_sharedport(state2.ports, port) do
                nil ->
                  state2 =
                    send!(state2, ["portopen", portname, ref, Wallet.address!(state.node_id)])

                  ports = PortCollection.put(state2.ports, port)
                  {:noreply, %{state2 | ports: ports}}

                existing_port ->
                  port = %Port{existing_port | clients: [client | existing_port.clients]}
                  ports = PortCollection.put(state2.ports, port)
                  {:reply, {:ok, state2.socket, existing_port.ref}, %{state2 | ports: ports}}
              end

            _other ->
              {:reply, {:error, "already opening"}, state2}
          end
        end)
      catch
        kind, what ->
          IO.puts("Remote port failed ack on portopen: #{inspect({kind, what})}")
          {:error, "#{inspect(kind)}"}
      end

    case resp do
      {:ok, socket2, cref} ->
        state = send!(state, ["response", "portopen", "ok", ref])

        client = %PortClient{
          pid: pid,
          mon: mon,
          socket: socket2,
          ref: cref,
          write: String.contains?(flags, "w")
        }

        ports = PortCollection.put(state.ports, %Port{state: :open, clients: [client], ref: ref})

        {:noreply, %{state | ports: ports}}

      {:error, reason} ->
        Process.demonitor(mon, [:flush])
        state = send!(state, ["error", "portopen", reason, ref])
        {:noreply, state}
    end
  end

  defp portclose(state, ref, action \\ true)

  # Closing whole port no matter how many clients
  defp portclose(state, port = %Port{}, action) do
    for client <- port.clients do
      GenServer.cast(client.pid, fn state2 -> {:noreply, portclose(state2, port.ref)} end)
      Process.demonitor(client.mon, [:flush])
    end

    state =
      if action do
        send!(state, ["portclose", port.ref])
      else
        state
      end

    %{state | ports: PortCollection.delete(state.ports, port.ref)}
  end

  # Removing client but keeping port open if still >0 clients
  defp portclose(state, clientmon, action) when is_reference(clientmon) do
    do_portclose(state, PortCollection.get_clientmon(state.ports, clientmon), action)
  end

  defp portclose(state, clientref, action) do
    do_portclose(state, PortCollection.get_clientref(state.ports, clientref), action)
  end

  defp do_portclose(state, nil, _action) do
    state
  end

  defp do_portclose(state, {client, %Port{clients: [client], ref: ref}}, action) do
    Process.demonitor(client.mon, [:flush])

    state =
      if action do
        send!(state, ["portclose", ref])
      else
        state
      end

    %{state | ports: PortCollection.delete(state.ports, ref)}
  end

  defp do_portclose(state, {client, port}, _action) do
    Process.demonitor(client.mon, [:flush])

    %{
      state
      | ports:
          PortCollection.put(state.ports, %Port{port | clients: List.delete(port.clients, client)})
    }
  end

  defp decode(msg) do
    case Json.decode(msg) do
      {:ok, obj} -> obj
      _ -> nil
    end
  end

  defp encode(msg) do
    Json.encode!(msg)
  end

  defp send!(state, data) do
    msg = encode(data)
    :ok = :ssl.send(state.socket, msg)
    account_outgoing(state, msg)
  end

  @spec nodeid(state()) :: Wallet.t()
  def nodeid(%{node_id: id}), do: id

  defp account_outgoing(state, msg), do: account(state, msg)
  defp account_incoming(state, msg), do: account(state, msg)

  defp account(state = %{unpaid_bytes: b}, msg) do
    if b > 1024 * 40960 do
      send(self(), :stop_unpaid)
    end

    %{state | unpaid_bytes: b + byte_size(msg)}
  end

  def on_exit(_edge) do
    :ok
  end
end

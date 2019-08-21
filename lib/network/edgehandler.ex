defmodule Network.EdgeHandler do
  use GenServer
  alias Object.Location, as: Location
  import Location

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

  @type state :: %{socket: any(), node_id: any(), peer: tuple(), ports: PortCollection.t()}
  @spec init(state()) :: {:ok, state()}
  def init(state) do
    {:ok, peer} = :ssl.peername(state.socket)
    PubSub.subscribe({:edge, Wallet.address!(state.node_id)})
    :io.format("Edgehandler:init #{Wallet.printable(state.node_id)} from ~200p~n", [peer])

    state =
      Map.merge(state, %{
        peer: peer,
        ports: %PortCollection{}
      })

    {:ok, state}
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

  def handle_info({:ssl, socket, msg}, state) do
    msg = decode(msg)

    case msg do
      ["hello", block, device_signature] ->
        dl =
          location(
            server_id: Wallet.address!(Store.wallet()),
            peak_block: block,
            device_signature: device_signature
          )

        if Location.device_verify(dl, state.node_id) do
          dl = Location.server_sign(dl, Wallet.privkey!(Store.wallet()))
          Kademlia.store(Object.key(dl), Object.encode!(dl))
          send!(socket, ["response", "hello", "thanks!"])
        else
          send!(socket, ["error", "hello", "signature mismatch"])
        end

        {:noreply, state}

      ["ping"] ->
        send!(socket, ["response", "ping", "pong"])
        {:noreply, state}

      ["getobject", key] ->
        value =
          case Kademlia.find_value(key) do
            nil -> nil
            binary -> Object.encode_list!(Object.decode!(binary))
          end

        send!(socket, ["response", "getobject", value])
        {:noreply, state}

      ["getnode", node] ->
        ret =
          case Kademlia.find_node(node) do
            nil -> nil
            item -> Object.encode_list!(KBuckets.object(item))
          end

        send!(socket, ["response", "getnode", ret])
        {:noreply, state}

      ["getblockpeak"] ->
        send!(socket, ["response", "getblockpeak", Chain.peak()])
        {:noreply, state}

      ["getblock", index] when is_integer(index) ->
        send!(socket, ["response", "getblock", Chain.block(index)])
        {:noreply, state}

      ["getblockheader", index] when is_integer(index) ->
        send!(socket, ["response", "getblockheader", Chain.block(index).header])
        {:noreply, state}

      ["getstateroots", index] ->
        merkel = Chain.state(index).store
        send!(socket, ["response", "getstateroots", MerkleTree.root_hashes(merkel)])
        {:noreply, state}

      ["getaccount", index, id] ->
        mstate = Chain.state(index)

        case Chain.State.account(mstate, id) do
          nil ->
            send!(socket, ["error", "getaccount", "account does not exist"])

          account = %Chain.Account{} ->
            proof = MerkleTree.get_proofs(mstate.store, id)

            send!(socket, [
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

        case Chain.State.account(mstate, id) do
          nil ->
            send!(socket, ["error", "getaccountroots", "account does not exist"])

          %Chain.Account{storageRoot: storageRoot} ->
            send!(socket, [
              "response",
              "getaccountroots",
              MerkleTree.root_hashes(storageRoot)
            ])
        end

        {:noreply, state}

      ["getaccountvalue", index, id, key] ->
        mstate = Chain.state(index)

        case Chain.State.account(mstate, id) do
          nil ->
            send!(socket, ["error", "getaccountvalue", "account does not exist"])

          %Chain.Account{storageRoot: storageRoot} ->
            send!(socket, [
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
            send!(socket, ["error", "portsend", "port does not exist"])
            {:noreply, state}

          %Port{state: :open, clients: clients} ->
            for client <- clients do
              if client.write do
                send!(client.socket, ["portsend", client.ref, data])
              end
            end

            send!(socket, ["response", "portsend", "ok"])
            {:noreply, state}
        end

      ["portclose", ref] ->
        case PortCollection.get(state.ports, ref) do
          nil ->
            send!(socket, ["error", "portsend", "port does not exit"])
            {:noreply, state}

          port = %Port{state: :open} ->
            send!(socket, ["response", "portclose", "ok"])
            {:noreply, portclose(state, port, false)}
        end

      nil ->
        send!(socket, ["error", 400, "that is not json"])
        :io.format("~p:Unhandled message: ~p~n", [__MODULE__, msg])
        {:noreply, state}

      _ ->
        send!(socket, ["error", 401, "bad input"])
        :io.format("~p:Unhandled message: ~p~n", [__MODULE__, msg])
        {:noreply, state}
    end
  end

  def handle_info({:topic, topic, message}, state) do
    send!(state.socket, [topic, message])
    {:noreply, state}
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

  defp portopen(state, device_id, portname, flags \\ "rw") do
    socket = state.socket

    cond do
      device_id == Wallet.address!(state.node_id) ->
        send!(socket, ["error", "portopen", "can't connect to yourself"])
        {:noreply, state}

      validate_flags(flags) == false ->
        send!(socket, ["error", "portopen", "invalid flags"])
        {:noreply, state}

      true ->
        with <<bin::binary-size(20)>> <- device_id,
             w <- Wallet.from_address(bin),
             [pid] <- PubSub.subscribers({:edge, Wallet.address!(w)}) do
          do_portopen(state, portname, flags, pid)
        else
          [] ->
            send!(socket, ["error", "portopen", "not found"])
            {:noreply, state}

          _other ->
            send!(socket, ["error", "portopen", "invalid address"])
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
                  send!(state2.socket, ["portopen", portname, ref, Wallet.address!(state.node_id)])

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
        send!(socket, ["response", "portopen", "ok", ref])

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
        send!(socket, ["error", "portopen", reason, ref])
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

    action && send!(state.socket, ["portclose", port.ref])
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
    action && send!(state.socket, ["portclose", ref])
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

  defp send!(socket, data) do
    :ok = :ssl.send(socket, encode(data))
  end
end

# Diode Server
# Copyright 2019 IoT Blockchain Technology Corporation LLC (IBTC)
# Licensed under the Diode License, Version 1.0
defmodule Network.EdgeV1 do
  use Network.Handler
  alias Object.Ticket, as: Ticket
  import Ticket, only: :macros

  defmodule PortClient do
    defstruct pid: nil, mon: nil, ref: nil, write: true

    @type t :: %PortClient{
            pid: pid(),
            mon: reference(),
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

    @type ref :: binary()
    @type t :: %Port{
            state: :open | :pre_open,
            ref: ref(),
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
    @type t :: %PortCollection{refs: %{Port.ref() => Port.t()}}

    @spec put(PortCollection.t(), Port.t()) :: PortCollection.t()
    def put(pc, port) do
      %{pc | refs: Map.put(pc.refs, port.ref, port)}
    end

    @spec delete(PortCollection.t(), Port.ref()) :: PortCollection.t()
    def delete(pc, ref) do
      %{pc | refs: Map.delete(pc.refs, ref)}
    end

    @spec get(PortCollection.t(), Port.ref(), any()) :: Port.t() | nil
    def get(pc, ref, default \\ nil) do
      Map.get(pc.refs, ref, default)
    end

    @spec get_clientref(PortCollection.t(), Port.ref()) :: {PortClient.t(), Port.t()} | nil
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
          compression: nil | :zlib,
          extra_flags: [],
          node_id: Wallet.t(),
          node_address: :inet.ip_address(),
          ports: PortCollection.t(),
          unpaid_bytes: integer(),
          unpaid_rx_bytes: integer(),
          last_ticket: integer()
        }

  def do_init(state) do
    PubSub.subscribe({:edge, device_address(state)})

    state =
      Map.merge(state, %{
        ports: %PortCollection{},
        compression: nil,
        extra_flags: [],
        unpaid_bytes: 0,
        unpaid_rx_bytes: 0,
        last_ticket: nil
      })

    log(state, "accepted connection")
    Process.send_after(self(), :must_have_ticket, 20_000)
    {:noreply, state}
  end

  def ssl_options(extra) do
    Network.Server.default_ssl_options(extra)
  end

  def handle_call({:portopen, this, ref, flags, portname, device_address}, from, state) do
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
          state: :pre_open,
          from: from,
          clients: [client],
          portname: portname,
          shared: String.contains?(flags, "s"),
          ref: ref
        }

        case PortCollection.find_sharedport(state.ports, port) do
          nil ->
            state = send!(state, ["portopen", portname, ref, device_address])

            ports = PortCollection.put(state.ports, port)
            {:noreply, %{state | ports: ports}}

          existing_port ->
            port = %Port{existing_port | clients: [client | existing_port.clients]}
            ports = PortCollection.put(state.ports, port)
            {:reply, {:ok, existing_port.ref}, %{state | ports: ports}}
        end

      _other ->
        {:reply, {:error, "already opening"}, state}
    end
  end

  def handle_cast({:portsend, ref, data, _pid}, state) do
    {:noreply, send!(state, ["portsend", ref, data])}
  end

  def handle_cast({:portclose, ref}, state) do
    {:noreply, portclose(state, ref)}
  end

  def handle_msg(msg, state) do
    case msg do
      ["hello", vsn | flags] ->
        if vsn != 1_000 do
          send(state, ["error", "hello", "version not supported"])
        else
          state1 =
            Enum.reduce(flags, state, fn flag, state ->
              case flag do
                "zlib" -> %{state | compression: :zlib}
                other -> %{state | extra_flags: [other | state.extra_flags]}
              end
            end)

          # If compression has been enabled then on the next frame
          state = send!(state, ["response", "hello", "ok"])
          %{state | compression: state1.compression, extra_flags: state1.extra_flags}
        end

      ["ticket" | rest = [_block, _fc, _tc, _tb, _la, _ds]] ->
        handle_ticket(rest, state)

      ["ping"] ->
        send!(state, ["response", "ping", "pong"])

      ["bytes"] ->
        send!(state, ["response", "bytes", state.unpaid_bytes])

      ["getobject", key] ->
        value =
          case Kademlia.find_value(key) do
            nil -> nil
            binary -> Json.prepare!(Object.encode_list!(Object.decode!(binary)), all_hex: true)
          end

        send!(state, ["response", "getobject", value])

      ["getnode", node] ->
        ret =
          case Kademlia.find_node(node) do
            nil -> nil
            item -> Object.encode_list!(KBuckets.object(item))
          end

        send!(state, ["response", "getnode", ret])

      ["getblockpeak"] ->
        send!(state, ["response", "getblockpeak", Chain.peak()])

      ["getblock", index] when is_integer(index) ->
        send!(state, ["response", "getblock", Chain.block(index)])

      ["getblockheader", index] when is_integer(index) ->
        send!(state, ["response", "getblockheader", block_header(index)])

      ["getblockheader2", index] when is_integer(index) ->
        header = block_header(index)
        pubkey = Chain.Header.recover_miner(header) |> Wallet.pubkey!()
        send!(state, ["response", "getblockheader2", header, pubkey])

      ["getblockquick", last_block, window_size]
      when is_integer(last_block) and
             is_integer(window_size) ->
        # this will throw if the block does not exist
        block_header(last_block)

        answ =
          get_blockquick_seq(last_block, window_size)
          |> Enum.map(fn num ->
            header = block_header(num)
            miner = Chain.Header.recover_miner(header) |> Wallet.pubkey!()
            {header, miner}
          end)

        send!(state, ["response", "getblockquick", answ])

      ["getblockquick2", last_block, window_size]
      when is_integer(last_block) and
             is_integer(window_size) ->
        answ = get_blockquick_seq(last_block, window_size)
        send!(state, ["response", "getblockquick2", answ])

      ["getstateroots", index] ->
        merkel = Chain.State.tree(Chain.state(index))
        send!(state, ["response", "getstateroots", MerkleTree.root_hashes(merkel)])

      ["getaccount", index, id] ->
        mstate = Chain.state(index)

        case Chain.State.account(mstate, id) do
          nil ->
            send!(state, ["error", "getaccount", "account does not exist"])

          account = %Chain.Account{} ->
            proof =
              Chain.State.tree(mstate)
              |> MerkleTree.get_proofs(id)

            send!(state, [
              "response",
              "getaccount",
              %{
                nonce: account.nonce,
                balance: account.balance,
                storage_root: Chain.Account.root_hash(account),
                code: Chain.Account.codehash(account)
              },
              proof
            ])
        end

      ["getaccountroots", index, id] ->
        mstate = Chain.state(index)

        case Chain.State.account(mstate, id) do
          nil ->
            send!(state, ["error", "getaccountroots", "account does not exist"])

          acc ->
            send!(state, [
              "response",
              "getaccountroots",
              MerkleTree.root_hashes(Chain.Account.tree(acc))
            ])
        end

      ["getaccountvalue", index, id, key] ->
        mstate = Chain.state(index)

        case Chain.State.account(mstate, id) do
          nil ->
            send!(state, ["error", "getaccountvalue", "account does not exist"])

          acc ->
            send!(state, [
              "response",
              "getaccountvalue",
              MerkleTree.get_proofs(Chain.Account.tree(acc), key)
            ])
        end

      ["portopen", device_id, port, flags] ->
        portopen(state, device_id, port, flags)

      ["portopen", device_id, port] ->
        portopen(state, device_id, port)

      ["response", "portopen", ref, "ok"] ->
        port = %Port{state: :pre_open} = PortCollection.get(state.ports, to_bin(ref))
        GenServer.reply(port.from, {:ok, ref})
        ports = PortCollection.put(state.ports, %Port{port | state: :open, from: nil})
        send!(%{state | ports: ports})

      ["error", "portopen", ref, reason] ->
        port = %Port{state: :pre_open} = PortCollection.get(state.ports, to_bin(ref))
        GenServer.reply(port.from, {:error, reason})
        portclose(state, port, false)

      ["portsend", ref, data] ->
        case PortCollection.get(state.ports, to_bin(ref)) do
          nil ->
            send!(state, ["error", "portsend", "port does not exist"])

          %Port{state: :open, clients: clients} ->
            for client <- clients do
              if client.write do
                GenServer.cast(client.pid, {:portsend, client.ref, data, self()})
              end
            end

            send!(state, ["response", "portsend", "ok"])
        end

      ["portclose", ref] ->
        case PortCollection.get(state.ports, to_bin(ref)) do
          nil ->
            send!(state, ["error", "portclose", "port does not exit"])

          port = %Port{state: :open} ->
            send!(state, ["response", "portclose", "ok"])
            |> portclose(port, false)
        end

      nil ->
        log(state, "Unhandled message: ~40s~n", [truncate(msg)])
        send!(state, ["error", 400, "that is not json"])

      _ ->
        log(state, "Unhandled message: ~40s~n", [truncate(msg)])
        send!(state, ["error", 401, "bad input"])
    end
  end

  def handle_info({:ssl, _socket, raw_msg}, state) do
    state = account_incoming(state, raw_msg)
    msg = decode(state, raw_msg)

    try do
      state = handle_msg(msg, state)
      {:noreply, state}
    catch
      :notfound ->
        log(state, "connection closed because non existing block was requested.")
        {:stop, :normal, state}
    end
  end

  def handle_info({:topic, topic, message}, state) do
    state = send!(state, [topic, message])
    {:noreply, state}
  end

  def handle_info({:stop_unpaid, b0}, state = %{unpaid_bytes: b}) do
    log(state, "connection closed because unpaid #{b0}(#{b}) bytes.")

    {:stop, :normal, state}
  end

  def handle_info(:must_have_ticket, state = %{last_ticket: timestamp}) do
    if timestamp == nil do
      log(state, "connection closed because no valid ticket sent within time limit.")
      {:stop, :normal, state}
    else
      {:noreply, state}
    end
  end

  def handle_info({:ssl_closed, _}, state) do
    log(state, "connection closed by remote.")
    {:stop, :normal, state}
  end

  def handle_info({:DOWN, mon, _type, _object, _info}, state) do
    {:noreply, portclose(state, mon)}
  end

  def handle_info(msg, state) do
    log(state, "Unhandled info: ~p", [msg])
    {:noreply, state}
  end

  defp handle_ticket(
         [block, fleet, total_connections, total_bytes, local_address, device_signature],
         state
       ) do
    dl =
      ticket(
        server_id: Wallet.address!(Diode.miner()),
        fleet_contract: fleet,
        total_connections: total_connections,
        total_bytes: total_bytes,
        local_address: local_address,
        block_number: block,
        device_signature: device_signature
      )

    device = Ticket.device_address(dl)

    cond do
      not Wallet.equal?(device, device_id(state)) ->
        log(state, "Received invalid ticket signature!")
        send!(state, ["error", "ticket", "signature mismatch"])

      not Contract.Fleet.device_whitelisted?(fleet, device) ->
        log(state, "Received invalid ticket fleet!")
        send!(state, ["error", "ticket", "device not whitelisted"])

      true ->
        dl = Ticket.server_sign(dl, Wallet.privkey!(Diode.miner()))

        case TicketStore.add(dl) do
          {:ok, bytes} ->
            key = Object.key(dl)

            Debouncer.immediate(key, fn ->
              Kademlia.store(key, Object.encode!(dl))
            end)

            %{state | unpaid_bytes: state.unpaid_bytes - bytes, last_ticket: Time.utc_now()}
            |> send!(["response", "ticket", "thanks!", bytes])

          {:too_old, min} ->
            send!(state, ["response", "ticket", "too_old", min])

          {:too_low, last} ->
            send!(state, [
              "response",
              "ticket",
              "too_low",
              Ticket.block_hash(last),
              Ticket.total_connections(last),
              Ticket.total_bytes(last),
              Ticket.local_address(last) |> Base16.encode(),
              Ticket.device_signature(last)
            ])
        end
    end
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
      device_id == Wallet.address!(device_id(state)) ->
        send!(state, ["error", "portopen", "can't connect to yourself"])

      validate_flags(flags) == false ->
        send!(state, ["error", "portopen", "invalid flags"])

      true ->
        with <<bin::binary-size(20)>> <- device_id,
             w <- Wallet.from_address(bin),
             [pid] <- PubSub.subscribers({:edge, Wallet.address!(w)}) do
          do_portopen(state, portname, flags, pid)
        else
          [] -> send!(state, ["error", "portopen", "not found"])
          _other -> send!(state, ["error", "portopen", "invalid address"])
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
    mon = Process.monitor(pid)
    ref = Random.uint31h() |> to_bin()
    # :io.format("REF ~p~n", [ref])
    this = self()
    device_address = device_address(state)

    #  Receives an open request from another local connected edge worker.
    #  Now needs to forward the request to the device and remember to
    #  keep in 'pre-open' state until the device acks.
    # Todo: Check for network access based on contract
    resp =
      try do
        GenServer.call(pid, {:portopen, this, ref, flags, portname, device_address})
      catch
        kind, what ->
          log(state, "Remote port failed ack on portopen: #{inspect({kind, what})}")
          {:error, "#{inspect(kind)}"}
      end

    case resp do
      {:ok, cref} ->
        state = send!(state, ["response", "portopen", "ok", ref])

        client = %PortClient{
          pid: pid,
          mon: mon,
          ref: cref,
          write: String.contains?(flags, "w")
        }

        ports = PortCollection.put(state.ports, %Port{state: :open, clients: [client], ref: ref})

        %{state | ports: ports}

      {:error, reason} ->
        Process.demonitor(mon, [:flush])
        send!(state, ["error", "portopen", reason, ref])
    end
  end

  defp portclose(state, ref, action \\ true)

  # Closing whole port no matter how many clients
  defp portclose(state, port = %Port{}, action) do
    for client <- port.clients do
      GenServer.cast(client.pid, {:portclose, port.ref})
      Process.demonitor(client.mon, [:flush])
    end

    state = if action, do: send!(state, ["portclose", port.ref]), else: state
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

  defp decode(state, msg) do
    msg =
      case state.compression do
        nil -> msg
        :zlib -> :zlib.unzip(msg)
      end

    case Json.decode(msg) do
      {:ok, obj} -> obj
      _ -> nil
    end
  end

  defp encode(nil) do
    ""
  end

  defp encode(msg) do
    Json.encode!(msg)
  end

  defp send!(state = %{unpaid_bytes: b, unpaid_rx_bytes: rx}, data \\ nil) do
    # log(state, "send: ~p", [data])

    msg =
      if b > Diode.ticket_grace() do
        send(self(), {:stop_unpaid, b})
        encode(["goodbye", "ticket expected", "you might get blacklisted"])
      else
        encode(data)
      end

    if msg != "", do: :ok = do_send!(state, msg)
    %{state | unpaid_bytes: b + byte_size(msg) + rx, unpaid_rx_bytes: 0}
  end

  defp do_send!(state, msg) do
    msg =
      case state.compression do
        nil -> msg
        :zlib -> :zlib.zip(msg)
      end

    :ssl.send(state.socket, msg)
  end

  @spec device_id(state()) :: Wallet.t()
  def device_id(%{node_id: id}), do: id
  def device_address(%{node_id: id}), do: Wallet.address!(id)

  defp account_incoming(state = %{unpaid_rx_bytes: b}, msg) do
    %{state | unpaid_rx_bytes: b + byte_size(msg)}
  end

  def on_nodeid(_edge) do
    :ok
  end

  defp get_blockquick_seq(last_block, window_size) do
    # Step 1: Identifying current view the device has
    #   based on it's current last valid block number
    window =
      Enum.map(1..window_size, fn idx ->
        Chain.Block.miner(Chain.block(last_block - idx))
        |> Wallet.pubkey!()
      end)

    counts = Enum.reduce(window, %{}, fn miner, acc -> Map.update(acc, miner, 1, &(&1 + 1)) end)

    threshold = div(window_size, 2)

    # Step 2: Findind a provable sequence
    #    Iterating from peak backwards until the block score is over 50% of the window_size
    {:ok, heads} =
      Enum.reduce_while(Chain.blocks(), {counts, 0, []}, fn block, {counts, score, heads} ->
        miner = Chain.Block.miner(block) |> Wallet.pubkey!()
        {value, counts} = Map.pop(counts, miner, 0)
        score = score + value
        heads = [Chain.Block.number(block) | heads]

        if score > threshold do
          {:halt, {:ok, heads}}
        else
          {:cont, {counts, score, heads}}
        end
      end)

    # Step 3: Filling gap between 'last_block' and provable sequence, but not
    # by more than 'window_size' block heads before the provable sequence
    begin = hd(heads)
    size = min(window_size, begin - last_block) - 1

    gap_fill =
      Enum.map((begin - size)..(begin - 1), fn block_number ->
        block_number
      end)

    gap_fill ++ heads

    # # Step 4: Checking whether the the provable sequence can be shortened
    # # TODO
    # {:ok, heads} =
    #   Enum.reduce_while(heads, {counts, 0, []}, fn {head, miner},
    #                                                {counts, score, heads} ->
    #     {value, counts} = Map.pop(counts, miner, 0)
    #     score = score + value
    #     heads = [{head, miner} | heads]

    #     if score > threshold do
    #       {:halt, {:ok, heads}}
    #     else
    #       {:cont, {counts, score, heads}}
    #     end
    #   end)
  end

  defp block_header(n) do
    case Chain.block(n) do
      nil -> throw(:notfound)
      block -> Chain.Header.strip_state(block.header)
    end
  end

  defp to_bin(bin) when is_binary(bin) do
    bin
  end

  defp to_bin(int) when is_integer(int) do
    :binary.encode_unsigned(int)
  end
end

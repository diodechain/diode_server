# Diode Server
# Copyright 2019 IoT Blockchain Technology Corporation LLC (IBTC)
# Licensed under the Diode License, Version 1.0
defmodule Network.EdgeV2 do
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
          last_ticket: integer(),
          pid: pid()
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
        last_ticket: nil,
        pid: self()
      })

    log(state, "accepted connection")
    Process.send_after(self(), :must_have_ticket, 20_000)
    {:noreply, state}
  end

  def ssl_options(extra) do
    Network.Server.default_ssl_options(extra)
  end

  def handle_call(fun, from, state) when is_function(fun) do
    fun.(from, state)
  end

  def handle_cast(fun, state) when is_function(fun) do
    fun.(state)
  end

  def handle_msg(msg, state) do
    case msg do
      ["hello", vsn | flags] when is_binary(vsn) ->
        if to_num(vsn) != 1_000 do
          {error("version not supported"), state}
        else
          state1 =
            Enum.reduce(flags, state, fn flag, state ->
              case flag do
                "zlib" -> %{state | compression: :zlib}
                other -> %{state | extra_flags: [other | state.extra_flags]}
              end
            end)

          # If compression has been enabled then on the next frame
          state = %{state | compression: state1.compression, extra_flags: state1.extra_flags}
          {response("ok"), state}
        end

      ["ticket" | rest = [_block, _fc, _tc, _tb, _la, _ds]] ->
        handle_ticket(rest, state)

      ["bytes"] ->
        # This is an exception as unpaid_bytes can be negative
        {response(Rlpx.int2bin(state.unpaid_bytes)), state}

      ["portsend", ref, data] ->
        case PortCollection.get(state.ports, ref) do
          nil ->
            error("port does not exist")

          %Port{state: :open, clients: clients} ->
            for client <- clients do
              if client.write do
                GenServer.cast(client.pid, fn cstate ->
                  {:noreply, send_socket(cstate, random_ref(), ["portsend", client.ref, data])}
                end)
              end
            end

            response("ok")
        end

      _other ->
        :async
    end
  end

  def handle_async_msg(msg, state) do
    case msg do
      ["ping"] ->
        response("pong")

      ["getobject", key] ->
        value =
          case Kademlia.find_value(key) do
            nil -> nil
            binary -> Object.encode_list!(Object.decode!(binary))
          end

        response(value)

      ["getnode", node] ->
        case Kademlia.find_node(node) do
          nil -> nil
          item -> Object.encode_list!(KBuckets.object(item))
        end
        |> response()

      ["getblockpeak"] ->
        response(Chain.peak())

      ["getblock", index] when is_binary(index) ->
        response(Chain.block(to_num(index)))

      ["getblockheader", index] when is_binary(index) ->
        response(block_header(to_num(index)))

      ["getblockheader2", index] when is_binary(index) ->
        header = block_header(to_num(index))
        pubkey = Chain.Header.recover_miner(header) |> Wallet.pubkey!()
        response(header, pubkey)

      ["getblockquick", last_block, window_size]
      when is_binary(last_block) and
             is_binary(window_size) ->
        window_size = to_num(window_size)
        last_block = to_num(last_block)
        # this will throw if the block does not exist
        block_header(last_block)

        get_blockquick_seq(last_block, window_size)
        |> Enum.map(fn num ->
          header = block_header(num)
          miner = Chain.Header.recover_miner(header) |> Wallet.pubkey!()
          {header, miner}
        end)
        |> response()

      ["getblockquick2", last_block, window_size]
      when is_binary(last_block) and
             is_binary(window_size) ->
        get_blockquick_seq(to_num(last_block), to_num(window_size))
        |> response()

      ["getstateroots", index] ->
        merkel = Chain.State.tree(Chain.state(to_num(index)))
        response(MerkleTree.root_hashes(merkel))

      ["getaccount", index, id] ->
        mstate = Chain.state(to_num(index))

        case Chain.State.account(mstate, id) do
          nil ->
            error("account does not exist")

          account = %Chain.Account{} ->
            proof =
              Chain.State.tree(mstate)
              |> MerkleTree.get_proofs(id)

            response(
              %{
                nonce: account.nonce,
                balance: account.balance,
                storage_root: Chain.Account.root_hash(account),
                code: Chain.Account.codehash(account)
              },
              proof
            )
        end

      ["getaccountroots", index, id] ->
        mstate = Chain.state(to_num(index))

        case Chain.State.account(mstate, id) do
          nil -> error("account does not exist")
          acc -> response(MerkleTree.root_hashes(Chain.Account.root(acc)))
        end

      ["getaccountvalue", index, id, key] ->
        mstate = Chain.state(to_num(index))

        case Chain.State.account(mstate, id) do
          nil -> error("account does not exist")
          acc -> response(MerkleTree.get_proofs(Chain.Account.root(acc), key))
        end

      ["portopen", device_id, port, flags] ->
        portopen(state, device_id, to_num(port), flags)

      ["portopen", device_id, port] ->
        portopen(state, device_id, to_num(port), "rw")

      # "portopen" response
      ["response", ref, "ok"] ->
        GenServer.call(state.pid, fn _from, state ->
          port = %Port{state: :pre_open} = PortCollection.get(state.ports, ref)
          GenServer.reply(port.from, {:ok, ref})
          ports = PortCollection.put(state.ports, %Port{port | state: :open, from: nil})
          {:reply, :ok, %{state | ports: ports}}
        end)

        nil

      # "portopen" error
      ["error", ref, reason] ->
        port = %Port{state: :pre_open} = PortCollection.get(state.ports, ref)
        GenServer.reply(port.from, {:error, reason})

        GenServer.call(state.pid, fn _from, state ->
          {:reply, :ok, portclose(state, port, false)}
        end)

        nil

      ["portclose", ref] ->
        case PortCollection.get(state.ports, ref) do
          nil ->
            error("port does not exit")

          port = %Port{state: :open} ->
            GenServer.call(state.pid, fn _from, state ->
              {:reply, :ok, portclose(state, port, false)}
            end)

            response("ok")
        end

      nil ->
        log(state, "Unhandled message: ~40s~n", [truncate(msg)])
        error(400, "that is not rlp")

      _ ->
        log(state, "Unhandled message: ~40s~n", [truncate(msg)])
        error(401, "bad input")
    end
  end

  defp response(arg) do
    response_array([arg])
  end

  defp response(arg, arg2) do
    response_array([arg, arg2])
  end

  defp response_array(args) do
    ["response" | args]
  end

  defp error(code, message) do
    ["error", code, message]
  end

  defp error(message) do
    ["error", message]
  end

  def handle_info({:ssl, _socket, raw_msg}, state) do
    state = account_incoming(state, raw_msg)
    msg = decode(state, raw_msg)

    # should be [request_id, method_params, opts]
    case msg do
      [request_id, method_params, opts] ->
        handle_request(state, to_num(request_id), method_params, opts)

      [request_id, method_params] ->
        handle_request(state, to_num(request_id), method_params, [])

      _other ->
        log(state, "connection closed because wrong message received.")
        {:stop, :normal, state}
    end
  end

  def handle_info({:topic, _topic, _message}, state) do
    throw(:notimpl)
    # state = send_socket(state, random_ref(), [topic, message])
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

  defp handle_request(state, request_id, method_params, _opts) do
    case handle_msg(method_params, state) do
      :async ->
        pid = self()

        spawn_link(fn ->
          result = handle_async_msg(method_params, state)

          GenServer.cast(pid, fn state2 ->
            {:noreply, send_socket(state2, request_id, result)}
          end)
        end)

        {:noreply, state}

      {result, state} ->
        {:noreply, send_socket(state, request_id, result)}

      result ->
        {:noreply, send_socket(state, request_id, result)}
    end
  end

  defp handle_ticket(
         [block, fleet_contract, total_connections, total_bytes, local_address, device_signature],
         state
       ) do
    dl =
      ticket(
        server_id: Wallet.address!(Diode.miner()),
        fleet_contract: fleet_contract,
        total_connections: to_num(total_connections),
        total_bytes: to_num(total_bytes),
        local_address: local_address,
        block_number: to_num(block),
        device_signature: device_signature
      )

    if Ticket.device_verify(dl, device_id(state)) do
      dl = Ticket.server_sign(dl, Wallet.privkey!(Diode.miner()))

      case TicketStore.add(dl) do
        {:ok, bytes} ->
          key = Object.key(dl)

          Debouncer.immediate(key, fn ->
            Kademlia.store(key, Object.encode!(dl))
          end)

          {response("thanks!", bytes),
           %{state | unpaid_bytes: state.unpaid_bytes - bytes, last_ticket: Time.utc_now()}}

        {:too_old, min} ->
          response("too_old", min)

        {:too_low, last} ->
          response_array([
            "too_low",
            Ticket.block_hash(last),
            Ticket.total_connections(last),
            Ticket.total_bytes(last),
            Ticket.local_address(last),
            Ticket.device_signature(last)
          ])
      end
    else
      log(state, "Received invalid ticket!")
      error("signature mismatch")
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

  defp portopen(state, device_id, portname, flags) do
    address = device_address(state)

    cond do
      device_id == address ->
        error("can't connect to yourself")

      validate_flags(flags) == false ->
        error("invalid flags")

      true ->
        with <<bin::binary-size(20)>> <- device_id,
             w <- Wallet.from_address(bin),
             [pid] <- PubSub.subscribers({:edge, Wallet.address!(w)}) do
          do_portopen(address, state.pid, portname, flags, pid)
        else
          [] -> error("not found")
          _other -> error("invalid address")
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

  defp random_ref() do
    Random.uint31h()
    |> to_bin()

    # :io.format("REF ~p~n", [ref])
  end

  defp do_portopen(device_address, this, portname, flags, pid) do
    mon = Process.monitor(pid)
    ref = random_ref()

    #  Receives an open request from another local connected edge worker.
    #  Now needs to forward the request to the device and remember to
    #  keep in 'pre-open' state until the device acks.
    # Todo: Check for network access based on contract
    resp =
      try do
        GenServer.call(pid, fn from, state2 ->
          case PortCollection.get(state2.ports, ref) do
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

              case PortCollection.find_sharedport(state2.ports, port) do
                nil ->
                  state2 =
                    send_socket(state2, random_ref(), ["portopen", portname, ref, device_address])

                  ports = PortCollection.put(state2.ports, port)
                  {:noreply, %{state2 | ports: ports}}

                existing_port ->
                  port = %Port{existing_port | clients: [client | existing_port.clients]}
                  ports = PortCollection.put(state2.ports, port)
                  {:reply, {:ok, existing_port.ref}, %{state2 | ports: ports}}
              end

            _other ->
              {:reply, {:error, "already opening"}, state2}
          end
        end)
      catch
        kind, what ->
          IO.puts("Remote port failed ack on portopen: #{inspect({kind, what})}")
          {:error, "#{inspect({kind, what})}"}
      end

    case resp do
      {:ok, cref} ->
        client = %PortClient{
          pid: pid,
          mon: mon,
          ref: cref,
          write: String.contains?(flags, "w")
        }

        GenServer.call(this, fn _from, state ->
          ports =
            PortCollection.put(state.ports, %Port{state: :open, clients: [client], ref: ref})

          {:reply, :ok, %{state | ports: ports}}
        end)

        response("ok", ref)

      {:error, reason} ->
        Process.demonitor(mon, [:flush])
        error("#{reason} #{ref}")
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
        {:current_stacktrace, what} = :erlang.process_info(self(), :current_stacktrace)
        :io.format("portclose from: ~p~n", [what])
        send_socket(state, random_ref(), ["portclose", port.ref])
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
        {:current_stacktrace, what} = :erlang.process_info(self(), :current_stacktrace)
        :io.format("portclose from: ~p~n", [what])
        send_socket(state, random_ref(), ["portclose", ref])
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
    case state.compression do
      nil -> msg
      :zlib -> :zlib.unzip(msg)
    end
    |> Rlp.decode!()
  end

  defp encode(nil) do
    ""
  end

  defp encode(msg) do
    Rlp.encode!(msg)
  end

  defp send_socket(state = %{unpaid_bytes: b, unpaid_rx_bytes: rx}, request_id, data) do
    log(state, "send: ~p", [data])

    msg =
      if b > Diode.ticket_grace() do
        send(self(), {:stop_unpaid, b})
        encode([random_ref(), ["goodbye", "ticket expected", "you might get blacklisted"]])
      else
        if data == nil do
          ""
        else
          encode([request_id, data])
        end
      end

    if msg != "", do: :ok = do_send_socket(state, msg)
    %{state | unpaid_bytes: b + byte_size(msg) + rx, unpaid_rx_bytes: 0}
  end

  defp do_send_socket(state, msg) do
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

  defp to_num(bin) do
    Rlpx.bin2num(bin)
  end

  defp to_bin(num) do
    Rlpx.num2bin(num)
  end
end

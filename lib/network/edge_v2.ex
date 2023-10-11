# Diode Server
# Copyright 2021 Diode
# Licensed under the Diode License, Version 1.1
defmodule Network.EdgeV2 do
  use Network.Handler
  require Logger
  alias Object.Ticket
  alias Object.Channel
  import Ticket, only: :macros
  import Channel, only: :macros

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
              shared: false,
              mailbox: :queue.new()

    @type ref :: binary()
    @type t :: %Port{
            state: :open | :pre_open,
            ref: ref(),
            from: nil | {pid(), reference()},
            clients: [PortClient.t()],
            portname: any(),
            shared: true | false,
            mailbox: :queue.queue(binary())
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
          inbuffer: nil | {integer(), binary()},
          blocked: :queue.queue(tuple()),
          compression: nil | :zlib,
          extra_flags: [],
          node_id: Wallet.t(),
          node_address: :inet.ip_address(),
          ports: PortCollection.t(),
          unpaid_bytes: integer(),
          unpaid_rx_bytes: integer(),
          last_ticket: Time.t(),
          last_message: Time.t(),
          pid: pid(),
          sender: pid()
        }

  def do_init(state) do
    PubSub.subscribe({:edge, device_address(state)})

    state =
      Map.merge(state, %{
        ports: %PortCollection{},
        inbuffer: nil,
        blocked: :queue.new(),
        compression: nil,
        extra_flags: [],
        unpaid_bytes: 0,
        unpaid_rx_bytes: 0,
        last_ticket: nil,
        last_message: Time.utc_now(),
        pid: self(),
        sender: Network.Sender.new(state.socket)
      })

    log(state, "accepted connection")
    {:noreply, must_have_ticket(state)}
  end

  defp must_have_ticket(state = %{last_ticket: last}) do
    Process.send_after(self(), {:must_have_ticket, last}, 20_000)
    state
  end

  def ssl_options(opts) do
    Network.Server.default_ssl_options(opts)
    |> Keyword.put(:packet, :raw)
  end

  def monitor(this, pid) do
    if self() == this do
      Process.monitor(pid)
    else
      call(this, {:monitor, pid})
    end
  end

  defp call(pid, msg, timeout \\ :infinity) do
    GenServer.call(pid, msg, timeout)
  end

  @impl true
  def handle_call(fun, from, state) when is_function(fun) do
    fun.(from, state)
  end

  def handle_call(:socket, _from, state) do
    {:reply, state.socket, state}
  end

  def handle_call({:socket_do, fun}, _from, state) do
    {:reply, fun.(state.socket), state}
  end

  def handle_call({:monitor, pid}, _from, state) do
    {:reply, Process.monitor(pid), state}
  end

  @max_preopen_ports 5
  def handle_call({:portopen, pid, ref, flags, portname, device_address}, from, state) do
    cond do
      Enum.count(state.ports.refs, fn {_key, %Port{state: pstate}} -> pstate == :pre_open end) >
          @max_preopen_ports ->
        # Send message to ensure this is still an active port
        Process.send_after(self(), {:check_activity, state.last_message}, 15_000)
        {:reply, {:error, "too many hanging ports"}, state}

      PortCollection.get(state.ports, ref) != nil ->
        {:reply, {:error, "already opening"}, state}

      true ->
        mon = monitor(state.pid, pid)

        client = %PortClient{
          mon: mon,
          pid: pid,
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
            state =
              send_socket(state, {:port, ref}, random_ref(), [
                "portopen",
                portname,
                ref,
                device_address
              ])

            ports = PortCollection.put(state.ports, port)
            {:noreply, %{state | ports: ports}}

          existing_port ->
            port = %Port{existing_port | clients: [client | existing_port.clients]}
            ports = PortCollection.put(state.ports, port)
            {:reply, {:ok, existing_port.ref}, %{state | ports: ports}}
        end
    end
  end

  @impl true
  def handle_cast(fun, state) when is_function(fun) do
    fun.(state)
  end

  def handle_cast({:portsend, ref, data, _pid}, state) do
    if PortCollection.get(state.ports, ref) != nil do
      {:noreply, send_socket(state, {:port, ref}, random_ref(), ["portsend", ref, data])}
    else
      {:noreply, state}
    end
  end

  def handle_cast({:portclose, ref}, state) do
    {:noreply, portclose(state, ref)}
  end

  def handle_cast(:stop, state) do
    log(state, "connection closed because of handshake anomaly.")
    {:stop, :normal, state}
  end

  @impl true
  def terminate(reason, %{sender: sender}) do
    # log(state, "Received terminate ~p ~p", [reason, state])
    if reason == :normal do
      Network.Sender.stop(sender)
    end

    reason
  end

  def terminate(reason, state) do
    log(state, "Received terminate before init ~p ~p", [reason, state])
    reason
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
                GenServer.cast(client.pid, {:portsend, client.ref, data, state.pid})
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
      ["m1:" <> cmd | rest] ->
        Network.EdgeM1.handle_async_msg([cmd | rest], state)

      ["ping"] ->
        response("pong")

      ["channel", block_number, fleet, type, name, params, signature] ->
        obj =
          channel(
            server_id: Diode.miner() |> Wallet.address!(),
            block_number: to_num(block_number),
            fleet_contract: fleet,
            type: type,
            name: name,
            params: params,
            signature: signature
          )

        device = Object.Channel.device_address(obj)

        cond do
          not Wallet.equal?(device, device_id(state)) ->
            error("invalid channel signature")

          not Contract.Fleet.device_allowlisted?(fleet, device) ->
            error("device not whitelisted for this fleet")

          not Object.Channel.valid_type?(obj) ->
            error("invalid channel type")

          not Object.Channel.valid_params?(obj) ->
            error("invalid channel parameters")

          true ->
            key = Object.Channel.key(obj)

            case Kademlia.find_value(key) do
              nil ->
                Kademlia.store(obj)
                Object.encode_list!(obj)

              binary ->
                Object.encode_list!(Object.decode!(binary))
            end
            |> response()
        end

      ["isonline", key] ->
        online = Map.get(Network.Server.get_connections(Network.EdgeV2), key) != nil
        response(online)

      ["getobject", key] ->
        case Kademlia.find_value(key) do
          nil -> nil
          binary -> Object.encode_list!(Object.decode!(binary))
        end
        |> response()

      ["getnode", node] ->
        case Kademlia.find_node(node) do
          nil -> nil
          item -> Object.encode_list!(KBuckets.object(item))
        end
        |> response()

      ["getblockpeak"] ->
        response(Chain.peak())

      ["getblock", index] when is_binary(index) ->
        response(BlockProcess.with_block(to_num(index), &Chain.Block.export(&1)))

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
        BlockProcess.with_block(to_num(index), fn block ->
          Chain.Block.state_tree(block)
          |> MerkleTree.root_hashes()
        end)
        |> response()

      ["getaccount", index, id] ->
        BlockProcess.with_block(to_num(index), fn block ->
          Chain.Block.state(block)
          |> Chain.State.account(id)
          |> case do
            nil ->
              error("account does not exist")

            account = %Chain.Account{} ->
              proof =
                Chain.Block.state_tree(block)
                |> MerkleTree.get_proofs(id)

              response(
                %{
                  nonce: account.nonce,
                  balance: account.balance,
                  storage_root: MerkleTree.root_hash(Chain.Block.account_tree(block, id)),
                  code: Chain.Account.codehash(account)
                },
                proof
              )
          end
        end)

      ["getaccountroots", index, id] ->
        BlockProcess.with_account_tree(to_num(index), id, fn
          nil -> error("account does not exist")
          tree -> response(MerkleTree.root_hashes(tree))
        end)

      ["getaccountvalue", index, id, key] ->
        BlockProcess.with_account_tree(to_num(index), id, fn
          nil -> error("account does not exist")
          tree -> response(MerkleTree.get_proofs(tree, key))
        end)

      ["getaccountvalues", index, id | keys] ->
        BlockProcess.with_account_tree(to_num(index), id, fn
          nil ->
            error("account does not exist")

          tree ->
            response(
              Enum.map(keys, fn key ->
                MerkleTree.get_proofs(tree, key)
              end)
            )
        end)

      ["portopen", device_id, port, flags] ->
        portopen(state, device_id, to_num(port), flags)

      ["portopen", device_id, port] ->
        portopen(state, device_id, to_num(port), "rw")

      # "portopen" response
      ["response", ref, "ok"] ->
        call(state.pid, fn _from, state ->
          case PortCollection.get(state.ports, ref) do
            port = %Port{state: :pre_open} ->
              GenServer.reply(port.from, {:ok, ref})
              ports = PortCollection.put(state.ports, %Port{port | state: :open, from: nil})
              {:reply, :ok, %{state | ports: ports}}

            nil ->
              log(state, "ignoring response for undefined ref ~p", [ref])
              {:reply, :ok, state}
          end
        end)

        nil

      # "portopen" error
      ["error", ref, reason] ->
        port = %Port{state: :pre_open} = PortCollection.get(state.ports, ref)
        GenServer.reply(port.from, {:error, reason})

        call(state.pid, fn _from, state ->
          {:reply, :ok, portclose(state, port, false)}
        end)

        nil

      ["portclose", ref] ->
        case PortCollection.get(state.ports, ref) do
          nil ->
            error("port does not exit")

          port = %Port{state: :open} ->
            call(state.pid, fn _from, state ->
              {:reply, :ok, portclose(state, port, false)}
            end)

            response("ok")
        end

      ["sendtransaction", tx] ->
        # Testing transaction
        tx = Chain.Transaction.from_rlp(tx)

        err =
          Chain.with_peak(fn peak ->
            state = Chain.Block.state(peak)

            case Chain.Transaction.apply(tx, peak, state) do
              {:ok, _state, %{msg: :ok}} -> nil
              {:ok, _state, rcpt} -> "Transaction exception: #{rcpt.msg}"
              {:error, :nonce_too_high} -> nil
              {:error, reason} -> "Transaction failed: #{inspect(reason)}"
            end
          end)

        # Adding transacton, even when :nonce_too_high
        if err == nil do
          Chain.Pool.add_transaction(tx, true)

          if Diode.dev_mode?() do
            Chain.Worker.work()
          end

          response("ok")
        else
          error(400, err)
        end

      nil ->
        log(state, "Unhandled message: ~40s~n", [truncate(msg)])
        error(400, "that is not rlp")

      _ ->
        log(state, "Unhandled message: ~40s~n", [truncate(msg)])
        error(401, "bad input")
    end
  end

  def response(arg) do
    response_array([arg])
  end

  def response(arg, arg2) do
    response_array([arg, arg2])
  end

  defp response_array(args) do
    ["response" | args]
  end

  def error(code, message) do
    ["error", code, message]
  end

  def error(message) do
    ["error", message]
  end

  defp handle_packet(raw_msg, state) do
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

  defp handle_data("", state) do
    {:noreply, state}
  end

  defp handle_data(<<0::unsigned-size(16), rest::binary>>, state = %{inbuffer: nil}) do
    handle_data(rest, state)
  end

  defp handle_data(<<length::unsigned-size(16), raw_msg::binary>>, state = %{inbuffer: nil}) do
    handle_data(length, raw_msg, state)
  end

  defp handle_data(<<more::binary>>, state = %{inbuffer: {length, buffer}}) do
    handle_data(length, buffer <> more, %{state | inbuffer: nil})
  end

  defp handle_data(length, raw_msg, state) do
    if byte_size(raw_msg) >= length do
      {:noreply, state} = handle_packet(binary_part(raw_msg, 0, length), state)
      rest = binary_part(raw_msg, length, byte_size(raw_msg) - length)
      handle_data(rest, %{state | inbuffer: nil})
    else
      {:noreply, %{state | inbuffer: {length, raw_msg}}}
    end
  end

  @impl true
  def handle_info({:check_activity, then_last_message}, state = %{last_message: now_last_message}) do
    if then_last_message == now_last_message do
      {:stop, :no_activity_timeout, state}
    else
      {:noreply, state}
    end
  end

  def handle_info({:ssl, _socket, data}, state) do
    handle_data(data, %{state | last_message: Time.utc_now()})
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

  def handle_info({:must_have_ticket, last}, state = %{last_ticket: timestamp}) do
    if timestamp == nil or timestamp == last do
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
            {:noreply, send_socket(state2, request_id, request_id, result)}
          end)
        end)

        {:noreply, state}

      {result, state} ->
        {:noreply, send_socket(state, request_id, request_id, result)}

      result ->
        {:noreply, send_socket(state, request_id, request_id, result)}
    end
  end

  defp handle_ticket(
         [block, fleet, total_connections, total_bytes, local_address, device_signature],
         state
       ) do
    dl =
      ticket(
        server_id: Wallet.address!(Diode.miner()),
        fleet_contract: fleet,
        total_connections: to_num(total_connections),
        total_bytes: to_num(total_bytes),
        local_address: local_address,
        block_number: to_num(block),
        device_signature: device_signature
      )

    cond do
      Ticket.block_number(dl) > Chain.peak() ->
        log(
          state,
          "Ticket with future block number #{Ticket.block_number(dl)} vs. #{Chain.peak()}!"
        )

        error("block number too high")

      not Ticket.device_address?(dl, device_id(state)) ->
        log(state, "Received invalid ticket signature!")
        error("signature mismatch")

      # TODO: Needs to be re-enabled after dev-contract is all-yes
      # not Contract.Fleet.device_allowlisted?(fleet, device) ->
      #   log(state, "Received invalid ticket fleet!")
      #   error("device not whitelisted")

      true ->
        dl = Ticket.server_sign(dl, Wallet.privkey!(Diode.miner()))
        ret = TicketStore.add(dl, device_id(state))

        # address = Ticket.device_address(dl)
        # short = String.slice(Base16.encode(address), 0..7)
        # total = Ticket.total_bytes(dl)
        # unpaid = state.unpaid_bytes
        # IO.puts("[#{short}] TICKET total: #{total} unpaid: #{unpaid} ret => #{inspect(ret)}")

        case ret do
          {:ok, bytes} ->
            key = Object.key(dl)

            # Storing the updated ticket of this device, debounce is 15 sec
            Debouncer.immediate(
              key,
              fn ->
                Model.KademliaSql.put_object(Kademlia.hash(key), Object.encode!(dl))
                Kademlia.store(dl)
              end,
              15_000
            )

            # Storing the updated ticket of this device, debounce is 10 sec
            Debouncer.immediate(
              :publish_me,
              fn ->
                me = Diode.self()
                Kademlia.store(me)
              end,
              10_000
            )

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

  defp portopen(state, <<channel_id::binary-size(32)>>, portname, flags) do
    case Kademlia.find_value(channel_id) do
      nil ->
        error("not found")

      bin ->
        channel = Object.decode!(bin)

        Object.Channel.server_id(channel)
        |> Wallet.from_address()
        |> Wallet.equal?(Diode.miner())
        |> if do
          pid = Channels.ensure(channel)
          do_portopen(state, device_address(state), state.pid, portname, flags, pid)
        else
          error("wrong host")
        end
    end
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
             [pid | _] <- PubSub.subscribers({:edge, Wallet.address!(w)}) do
          do_portopen(state, address, state.pid, portname, flags, pid)
        else
          [] -> error("not found")
          other -> error("invalid address #{inspect(other)}")
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

  defp do_portopen(state, device_address, this, portname, flags, pid) do
    mon = monitor(this, pid)
    ref = random_ref()

    #  Receives an open request from another local connected edge worker.
    #  Now needs to forward the request to the device and remember to
    #  keep in 'pre-open' state until the device acks.
    # Todo: Check for network access based on contract
    resp =
      try do
        call(pid, {:portopen, this, ref, flags, portname, device_address}, 35_000)
      catch
        kind, what ->
          log(
            state,
            "Portopen failed for #{Base16.encode(device_address)} #{inspect({kind, what})}"
          )

          :error
      end

    case resp do
      {:ok, cref} ->
        client = %PortClient{
          pid: pid,
          mon: mon,
          ref: cref,
          write: String.contains?(flags, "w")
        }

        call(this, fn _from, state ->
          ports =
            PortCollection.put(state.ports, %Port{state: :open, clients: [client], ref: ref})

          {:reply, :ok, %{state | ports: ports}}
        end)

        response("ok", ref)

      {:error, reason} ->
        Process.demonitor(mon, [:flush])
        error(reason)

      :error ->
        Process.demonitor(mon, [:flush])
        error(ref)
    end
  end

  defp portclose(state, ref, action \\ true)

  # Closing whole port no matter how many clients
  defp portclose(state, port = %Port{}, action) do
    for client <- port.clients do
      GenServer.cast(client.pid, {:portclose, port.ref})
      Process.demonitor(client.mon, [:flush])
    end

    state =
      if action do
        # {:current_stacktrace, what} = :erlang.process_info(self(), :current_stacktrace)
        # :io.format("portclose from: ~p~n", [what])
        send_socket(state, {:port, port.ref}, random_ref(), ["portclose", port.ref])
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
        # {:current_stacktrace, what} = :erlang.process_info(self(), :current_stacktrace)
        # :io.format("portclose from: ~p~n", [what])
        send_socket(state, {:port, ref}, random_ref(), ["portclose", ref])
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

  defp encode(msg) do
    Rlp.encode!(msg)
  end

  defp is_portsend({:port, _}), do: true
  defp is_portsend(_), do: false

  defp send_threshold() do
    Diode.ticket_grace() - Diode.ticket_grace() / 4
  end

  defp send_socket(
         state = %{unpaid_bytes: unpaid},
         partition,
         request_id,
         data
       ) do
    cond do
      # early exit
      unpaid > Diode.ticket_grace() ->
        send(self(), {:stop_unpaid, unpaid})
        msg = encode([random_ref(), ["goodbye", "ticket expected", "you might get blocked"]])
        :ok = do_send_socket(state, partition, msg)
        account_outgoing(state, msg)

      # stopping port data, and ensure there is a ticket within 20s
      unpaid > send_threshold() and is_portsend(partition) ->
        %{state | blocked: :queue.in({partition, request_id, data}, state.blocked)}
        |> account_outgoing()
        |> must_have_ticket()

      true ->
        state =
          if data == nil do
            account_outgoing(state)
          else
            msg = encode([request_id, data])
            :ok = do_send_socket(state, partition, msg)
            account_outgoing(state, msg)
          end

        # continue port data sending?
        if state.unpaid_bytes < send_threshold() and not :queue.is_empty(state.blocked) do
          {{:value, {partition, request_id, data}}, blocked} = :queue.out(state.blocked)
          send_socket(%{state | blocked: blocked}, partition, request_id, data)
        else
          state
        end
    end
  end

  defp do_send_socket(state, partition, msg) do
    msg =
      case state.compression do
        nil -> msg
        :zlib -> :zlib.zip(msg)
      end

    length = byte_size(msg)
    Network.Sender.push_async(state.sender, partition, <<length::unsigned-size(16), msg::binary>>)
  end

  @spec device_id(state()) :: Wallet.t()
  def device_id(%{node_id: id}), do: id
  def device_address(%{node_id: id}), do: Wallet.address!(id)

  defp account_incoming(state = %{unpaid_rx_bytes: unpaid_rx}, msg) do
    %{state | unpaid_rx_bytes: unpaid_rx + byte_size(msg)}
  end

  defp account_outgoing(state = %{unpaid_bytes: unpaid, unpaid_rx_bytes: unpaid_rx}, msg \\ "") do
    %{state | unpaid_bytes: unpaid + unpaid_rx + byte_size(msg), unpaid_rx_bytes: 0}
  end

  def on_nodeid(_edge) do
    :ok
  end

  def get_blockquick_window(last_block, window_size) do
    hash = Chain.blockhash(last_block)

    window =
      Chain.Block.blockquick_window(hash)
      |> Enum.reverse()
      |> Enum.take(window_size)

    len = length(window)

    if len < window_size do
      next_block = last_block - len
      window ++ get_blockquick_window(next_block, window_size - len)
    else
      window
    end
  end

  def find_sequence(last_block, counts, score, threshold) do
    window =
      Chain.Block.blockquick_window(Chain.blockhash(last_block))
      |> Enum.reverse()

    Enum.reduce_while(window, {counts, score, last_block}, fn miner,
                                                              {counts, score, last_block} ->
      {score_value, counts} = Map.pop(counts, miner, 0)
      score = score + score_value

      if score > threshold do
        {:halt, {:ok, last_block}}
      else
        {:cont, {counts, score, last_block - 1}}
      end
    end)
    |> case do
      {:ok, last_block} ->
        {:ok, last_block}

      {counts, score, last_block} ->
        find_sequence(last_block, counts, score, threshold)
    end
  end

  def get_blockquick_seq(last_block, window_size) do
    # Step 1: Identifying current view the device has
    #   based on it's current last valid block number
    window = get_blockquick_window(last_block, window_size)
    counts = Enum.reduce(window, %{}, fn miner, acc -> Map.update(acc, miner, 1, &(&1 + 1)) end)
    threshold = div(window_size, 2)

    # Step 2: Findind a provable sequence
    #    Iterating from peak backwards until the block score is over 50% of the window_size
    peak = Chain.peak()
    {:ok, provable_block} = find_sequence(peak, counts, 0, threshold)

    # Step 3: Filling gap between 'last_block' and provable sequence, but not
    # by more than 'window_size' block heads before the provable sequence
    begin = provable_block
    size = max(min(window_size, begin - last_block) - 1, 1)

    gap_fill = Enum.to_list((begin - size)..(begin - 1))
    gap_fill ++ Enum.to_list(begin..peak)

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
    BlockProcess.with_block(n, fn
      nil -> nil
      block -> Chain.Header.strip_state(block.header)
    end) || check_block(n)
  end

  @spec check_block(integer()) :: no_return()
  defp check_block(n) do
    if is_integer(n) and n < Chain.peak() do
      # we had some cases of missing blocks
      # this means the async blockwriter did somehow? skip
      # putting this block on disk. If this happens (which is a bug)
      # the only course for recovery is to restart the node, which
      # triggers an integrity check
      Logger.error("missing block #{n}")
      System.halt(1)
    else
      Logger.info("block #{inspect(n)} not found")
      throw(:notfound)
    end
  end

  defp to_num(bin) do
    Rlpx.bin2num(bin)
  end

  defp to_bin(num) do
    Rlpx.num2bin(num)
  end
end

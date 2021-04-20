# Diode Server
# Copyright 2021 Diode
# Licensed under the Diode License, Version 1.1
defmodule Network.PeerHandler do
  use Network.Handler
  alias Chain.BlockCache, as: Block
  alias Object.Server, as: Server
  alias Model.KademliaSql

  # @hello 0
  # @response 1
  # @find_node 2
  # @find_value 3
  # @store 4
  # @publish 5
  @hello :hello
  @response :response
  @find_node :find_node
  @find_value :find_value
  @store :store

  @publish :publish
  @ping :ping
  @pong :pong

  def find_node, do: @find_node
  def find_value, do: @find_value
  def store, do: @store
  def publish, do: @publish
  def ping, do: @ping
  def pong, do: @pong

  def do_init(state) do
    send_hello(
      Map.merge(state, %{
        calls: :queue.new(),
        blocks: nil,
        random_blocks: 0,
        stable: false,
        msg_count: 0,
        start_time: System.os_time(:second),
        server: nil,
        job: nil
      })
    )
  end

  def ssl_options(opts) do
    Network.Server.default_ssl_options(opts)
    |> Keyword.put(:packet, 4)
  end

  def handle_cast({:rpc, call}, state) do
    send!(state, call)
    calls = :queue.in({call, nil}, state.calls)
    {:noreply, %{state | calls: calls}}
  end

  def handle_cast({:sync_done, ret}, state = %{blocks: blocks}) do
    case ret do
      %Chain.Block{} ->
        if Chain.Block.number(blocks.peak) <= Chain.Block.number(ret) do
          # delete backup list on first successfull block
          {:noreply, %{state | blocks: nil, random_blocks: 0, job: nil}}
        else
          # received a new block(s) in the meantime re-trigger sync
          handle_block(
            Chain.block_by_hash(Chain.Block.parent_hash(blocks.oldest)),
            blocks.oldest,
            state
          )
          |> case do
            {reply, state} when not is_atom(reply) ->
              send!(state, reply)
              {:noreply, state}

            other ->
              other
          end
        end

      _error ->
        err = "sync failed"
        {:stop, {:validation_error, err}, state}
    end
  end

  def handle_call({:rpc, call}, from, state) do
    send!(state, call)
    calls = :queue.in({call, from}, state.calls)
    {:noreply, %{state | calls: calls}}
  end

  defp encode(msg) do
    BertInt.encode!(msg)
  end

  defp decode(msg) do
    BertInt.decode!(msg)
  end

  defp send_hello(state) do
    {:ok, {addr, _port}} = :ssl.sockname(state.socket)
    hello = Diode.self(:erlang.list_to_binary(:inet.ntoa(addr)))

    send!(state, [@hello, Object.encode!(hello), Chain.genesis_hash()])

    receive do
      {:ssl, _socket, msg} ->
        msg = decode(msg)

        case hd(msg) do
          @hello ->
            handle_msg(msg, state)

          _ ->
            log(state, "expected hello message, but got ~p", [msg])
            {:stop, :normal, state}
        end
    after
      3_000 ->
        log(state, "expected hello message, timeout")
        {:stop, :normal, state}
    end
  end

  def handle_info({:ssl, _sock, omsg}, state) do
    msg = decode(omsg)

    # log(state, format("Received ~p bytes on ~p: ~180p", [byte_size(omsg), _sock, msg]))

    state = %{state | msg_count: state.msg_count + 1}

    # We consider this connection stable after at least 5 minutes and 10 messages
    state =
      if state.stable == false and
           state.msg_count > 10 and
           state.start_time + 300 < System.os_time(:second) do
        GenServer.cast(Kademlia, {:stable_node, state.node_id, state.server})
        %{state | stable: true}
      else
        state
      end

    case handle_msg(msg, state) do
      {reply, state} when not is_atom(reply) ->
        send!(state, reply)
        {:noreply, state}

      other ->
        other
    end
  end

  def handle_info({:ssl_closed, info}, state) do
    log(state, "Connection closed by remote. info: ~0p", [info])
    {:stop, :normal, state}
  end

  def handle_info(msg, state) do
    log(state, "unhandled info: ~180p", [msg])
    {:noreply, state}
  end

  defp handle_msg([@hello, server, genesis_hash], state) do
    genesis = Chain.genesis_hash()

    if genesis != genesis_hash do
      log(state, "wrong genesis: ~p ~p", [
        Base16.encode(genesis),
        Base16.encode(genesis_hash)
      ])

      {:stop, :normal, state}
    else
      GenServer.cast(
        self(),
        {:rpc, [Network.PeerHandler.publish(), Block.export(Chain.peak_block())]}
      )

      if Map.has_key?(state, :peer_port) do
        {:noreply, state}
      else
        server = Object.decode!(server)
        id = Wallet.address!(state.node_id)
        ^id = Object.key(server)

        port = Server.peer_port(server)

        log(state, "hello from: #{Wallet.printable(state.node_id)}")
        state = Map.put(state, :peer_port, port)
        GenServer.cast(Kademlia, {:register_node, state.node_id, server})
        {:noreply, %{state | server: server}}
      end
    end
  end

  defp handle_msg([@find_node, id], state) do
    nodes =
      Kademlia.find_node_lookup(id)
      |> Enum.filter(fn node -> not KBuckets.is_self(node) end)

    {[@response, @find_node | nodes], state}
  end

  defp handle_msg([@find_value, id], state) do
    reply =
      case KademliaSql.object(id) do
        nil ->
          nodes =
            Kademlia.find_node_lookup(id)
            |> Enum.filter(fn node -> not KBuckets.is_self(node) end)

          [@response, @find_node | nodes]

        value ->
          [@response, @find_value, value]
      end

    {reply, state}
  end

  defp handle_msg([@store, key, value], state) do
    KademliaSql.put_object(key, value)
    {[@response, @store, "ok"], state}
  end

  defp handle_msg([@ping], state) do
    {[@response, @ping, @pong], state}
  end

  defp handle_msg([@pong], state) do
    {[@response, @pong, @ping], state}
  end

  defp handle_msg([@publish, %Chain.Transaction{} = tx], state) do
    if Chain.Transaction.valid?(tx) do
      Chain.Pool.add_transaction(tx)
      {[@response, @publish, "ok"], state}
    else
      {[@response, @publish, "error"], state}
    end
  end

  defp handle_msg([@publish, blocks], state) when is_list(blocks) do
    # For better resource usage we only let one process sync at full
    # throttle

    with %{peak: peak, oldest: oldest} <- state.blocks do
      len = Block.number(peak) - Block.number(oldest)

      Chain.throttle_sync(
        len > 10,
        "Downloading block #{Block.number(oldest)}/#{Block.number(peak)} (#{
          Chain.peak() - Block.number(oldest)
        }) from #{name(state)}"
      )
    end

    # Actual syncing
    prev_oldest = get_in(state, [:blocks, :oldest])

    Enum.reduce_while(blocks, {"ok", state}, fn block, {_, state} ->
      case handle_msg([@publish, block], state) do
        {response, state} -> {:cont, {response, state}}
        other -> {:halt, other}
      end
    end)
    |> case do
      {response, state} ->
        if state.blocks == nil or state.blocks.oldest == prev_oldest do
          {[@response, @publish, "ok"], state}
        else
          {response, state}
        end

      other ->
        other
    end
  end

  defp handle_msg([@publish, %Chain.Block{} = block], state) do
    block = Block.export(block)

    case Chain.block_by_hash?(Chain.Block.hash(block)) do
      false ->
        handle_block(Block.parent(block), block, state)

      true ->
        log(state, "Chain.add_block: Skipping existing block #{Block.printable(block)}")
        {[@response, @publish, "ok"], state}
    end
  end

  defp handle_msg([@response, @publish, "missing_parent", parent_hash], state) do
    # if there is a missing parent we're batching 65k blocks at once
    parents =
      Enum.reduce_while(Chain.blocks(parent_hash), [], fn block, blocks ->
        next = [Block.export(block) | blocks]

        if byte_size(:erlang.term_to_binary(next)) > 260_000 do
          {:halt, next}
        else
          {:cont, next}
        end
      end)
      |> Enum.reverse()

    case parents do
      [] ->
        # Responding to initial call, removing it from the stack
        # e.g. from kademlia.ex `GenServer.cast(pid, {:rpc, msg})`
        err = :io_lib.format("missing_parent ~p but there is no such parent", [parent_hash])
        :io.format("~s~n", [err])
        respond(state, err)

      _other ->
        # Creating a second round to finish this, need to
        # retop the last call
        {{:value, call}, calls} = :queue.out(state.calls)
        calls = :queue.in(call, calls)
        send!(state, [@publish, parents])
        {:noreply, %{state | calls: calls}}
    end
  end

  defp handle_msg([@response, @find_value, value], state) do
    respond(state, {:value, value})
  end

  defp handle_msg([@response, _cmd | rest], state) do
    respond(state, rest)
  end

  defp handle_msg(msg, state) do
    log(state, "Unhandled: #{inspect(msg)}")
    {:noreply, state}
  end

  # Block is based on unknown predecessor
  # keep block in block backup list
  defp handle_block(nil, block = %Chain.Block{}, state = %{blocks: blocks}) do
    # Checking previous sync jobs
    case blocks do
      nil ->
        parent = Model.SyncSql.search_parent(block)
        {0, %{peak: block, oldest: parent}}

      %{peak: peak, oldest: oldest} ->
        if Block.number(oldest) <= Block.number(block) and
             Block.number(block) <= Block.number(peak) do
          {0, blocks}
        else
          parent = Model.SyncSql.search_parent(block)

          if Block.number(oldest) > Block.number(parent) do
            {0, %{blocks | oldest: parent}}
          else
            # this happens when there is a new top block created on the remote side
            if Block.parent_hash(block) == Block.hash(peak) do
              {0, %{blocks | peak: block}}
            else
              # is this a randomly broadcasted block or a chain re-org?
              # assuming reorg after n blocks
              if state.random_blocks < 5 do
                log(state, "ignoring wrong ordered block [~p]", [state.random_blocks + 1])
                {state.random_blocks + 1, blocks}
              else
                log(state, "restarting sync because of random blocks [~p]", [
                  state.random_blocks + 1
                ])

                {:error, :too_many_random_blocks}
              end
            end
          end
        end
    end
    |> case do
      {:error, reason} ->
        {:stop, {:sync_error, reason}, state}

      {random_blocks, blocks} ->
        # if a search_parent() returns a known block we start the syncs
        if Chain.block_by_hash?(Chain.Block.parent_hash(blocks.oldest)) do
          handle_block(
            Chain.block_by_hash(Chain.Block.parent_hash(blocks.oldest)),
            blocks.oldest,
            %{state | blocks: blocks, random_blocks: random_blocks}
          )

          # otherwise keep asking for more blocks
        else
          {[@response, @publish, "missing_parent", Block.parent_hash(blocks.oldest)],
           %{state | blocks: blocks, random_blocks: random_blocks}}
        end
    end
  end

  defp handle_block(_parent, block, state = %{job: job}) do
    if Chain.is_active_sync(true) and job == nil do
      me = self()

      job =
        spawn_link(fn ->
          ret =
            Stream.concat([block], Model.SyncSql.resolve(state.blocks))
            |> Chain.import_blocks()

          GenServer.cast(me, {:sync_done, ret})
        end)

      {[@response, @publish, "ok"], %{state | job: job}}
    else
      {[@response, @publish, "ok"], state}
    end
  end

  defp respond(state, msg) do
    {{:value, {_call, from}}, calls} = :queue.out(state.calls)

    if from != nil do
      :ok = GenServer.reply(from, msg)
    end

    {:noreply, %{state | calls: calls}}
  end

  defp send!(%{socket: socket}, data) do
    raw = encode(data)
    # log(state, format("Sending ~p bytes: ~p", [byte_size(raw), data]))
    :ok = :ssl.send(socket, raw)
  end

  def on_nodeid(nil) do
    :ok
  end

  def on_nodeid(node) do
    OnCrash.call(fn reason ->
      :io.format("Node ~p down for: ~180p~n", [Wallet.printable(node), reason])
      GenServer.cast(Kademlia, {:failed_node, node})
    end)
  end
end

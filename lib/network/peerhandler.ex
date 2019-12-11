# Diode Server
# Copyright 2019 IoT Blockchain Technology Corporation LLC (IBTC)
# Licensed under the Diode License, Version 1.0
defmodule Network.PeerHandler do
  use Network.Handler
  alias Chain.BlockCache, as: Block
  alias Object.Server, as: Server

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

  def find_node, do: @find_node
  def find_value, do: @find_value
  def store, do: @store
  def publish, do: @publish

  def do_init(state) do
    state =
      Map.merge(state, %{
        calls: :queue.new(),
        blocks: [],
        # the oldest parent we have sent over
        oldest_parent: nil
      })

    {:noreply, state, {:continue, :send_hello}}
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

  def handle_call(:ping, _from, state) do
    {:reply, :pong, state}
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

  def handle_continue(:send_hello, state) do
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

  def handle_info({:ssl, _socket, omsg}, state) do
    msg = decode(omsg)

    case handle_msg(msg, state) do
      {reply, state} when not is_atom(reply) ->
        send!(state, reply)
        {:noreply, state}

      other ->
        other
    end
  end

  def handle_info({:ssl_closed, info}, state) do
    log(state, "connection closed by remote. ~p", [info])
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
        {:rpc, [Network.PeerHandler.publish(), filter_block(Chain.peakBlock())]}
      )

      if Map.has_key?(state, :peer_port) do
        {:noreply, state}
      else
        server = Object.decode!(server)
        id = Wallet.address!(state.node_id)
        ^id = Object.key(server)

        port = Server.server_port(server)

        log(state, "hello from: #{Wallet.printable(state.node_id)}")
        state = Map.put(state, :peer_port, port)
        GenServer.cast(Kademlia, {:register_node, state.node_id, server})
        {:noreply, state}
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
      case KademliaStore.find(id) do
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
    KademliaStore.store(key, value)
    {[@response, @store, "ok"], state}
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
    throttle_sync(state)

    # Actual syncing
    {msg, state} =
      Enum.reduce_while(blocks, {"ok", state}, fn block, {_, state} ->
        case handle_msg([@publish, block], state) do
          {[@response, @publish, "missing_parent"], state} ->
            {:cont, {"missing_parent", state}}

          {[@response, @publish, "error"], state} ->
            {:halt, {"error", state}}

          {[@response, @publish, "ok"], state} ->
            {:halt, {"ok", state}}
        end
      end)

    {[@response, @publish, msg], state}
  end

  defp handle_msg([@publish, %Chain.Block{} = block], state) do
    block = %{block | receipts: []}

    case Block.parent(block) do
      # Block is based on unknown predecessor
      # keep block in block backup list
      nil ->
        blocks =
          case state.blocks do
            [] ->
              [block]

            blocks ->
              if Block.parent_hash(hd(blocks)) == Block.hash(block) do
                [block | blocks]
              else
                # this happens when there is a new top block created on the remote side
                if Block.parent_hash(block) == Block.hash(List.last(blocks)) do
                  blocks ++ [block]
                else
                  # this could now be considered an error case
                  log(state, "ignoring wrong ordered block from")
                  blocks
                end
              end
          end

        {[@response, @publish, "missing_parent"], %{state | blocks: blocks}}

      %Chain.Block{} ->
        case Block.validate(block) do
          %Chain.Block{} = block ->
            Chain.add_block(block, false)

            # replay block backup list
            Enum.each(state.blocks, fn oldblock ->
              with %Chain.Block{} <- Block.parent(oldblock),
                   block_hash <- Block.hash(oldblock) do
                if Chain.block_by_hash(block_hash) != nil do
                  log(state, "Chain.add_block: Skipping existing block")
                else
                  case Block.validate(oldblock) do
                    %Chain.Block{} = block ->
                      throttle_sync(state, true)
                      Chain.add_block(block, false)

                    _ ->
                      :ok
                  end
                end
              end
            end)

            if Process.whereis(:active_sync) == self() do
              Process.unregister(:active_sync)
              PubSub.publish(:rpc, {:rpc, :syncing, false})
            end

            # delete backup list on first successfull block
            {[@response, @publish, "ok"], %{state | blocks: []}}

          _ ->
            err = "sync failed: #{inspect(Block.validate(block))}"
            {:stop, {:validation_error, err}}
        end
    end
  end

  defp handle_msg(msg = [@response, @publish, "missing_parent"], state = %{oldest_parent: nil}) do
    {:value, {[@publish, %Chain.Block{} = block], _from}} = :queue.peek(state.calls)
    handle_msg(msg, %{state | oldest_parent: block})
  end

  defp handle_msg([@response, @publish, "missing_parent"], state = %{oldest_parent: block}) do
    parent_hash = Block.parent_hash(block)

    # if there is a missing parent we're batching 65k blocks at once
    parents =
      Enum.reduce_while(Chain.blocks(parent_hash), [], fn block, blocks ->
        next = [filter_block(block) | blocks]

        if byte_size(:erlang.term_to_binary(next)) > 260_000 do
          {:halt, next}
        else
          {:cont, next}
        end
      end)
      |> Enum.reverse()

    case parents do
      [] ->
        respond(state, "missing_parent")

      _other ->
        send!(state, [@publish, parents])
        {:noreply, %{state | oldest_parent: List.last(parents)}}
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

  defp filter_block(%Chain.Block{} = block) do
    %Chain.Block{block | receipts: []}
  end

  defp throttle_sync(state, register \\ false) do
    # For better resource usage we only let one process sync at full
    # throttle
    case Process.whereis(:active_sync) do
      nil ->
        if register do
          Process.register(self(), :active_sync)
          PubSub.publish(:rpc, {:rpc, :syncing, true})
        end

        log(state, "Syncing ...")

      pid ->
        if pid != self() do
          log(state, "Syncing slow ...")
          Process.sleep(1000)
        else
          log(state, "Syncing ...")
        end
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
    # log(state, "send ~p", [data])
    :ok = :ssl.send(socket, encode(data))
  end

  def on_exit(node) do
    GenServer.cast(Kademlia, {:failed_node, node})
  end
end

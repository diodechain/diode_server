defmodule Network.PeerHandler do
  alias Chain.Block

  use GenServer
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

  def init(state) do
    {:ok, {address, _port}} = :ssl.peername(state.socket)

    state =
      Map.merge(state, %{
        calls: :queue.new(),
        peer_address: address,
        blocks: [],
        # the oldest parent we have sent over
        oldest_parent: nil
      })

    {:ok, state, {:continue, :send_hello}}
  end

  def ssl_options() do
    Network.Server.default_ssl_options()
    |> Keyword.put(:packet, 4)
  end

  def handle_cast({:rpc, call}, state) do
    # :io.format("rpc(~p)~n", [call])
    send!(state.socket, call)
    calls = :queue.in({call, nil}, state.calls)
    {:noreply, %{state | calls: calls}}
  end

  def handle_call(:ping, _from, state) do
    {:reply, :pong, state}
  end

  def handle_call({:rpc, call}, from, state) do
    # :io.format("rpc(~p)~n", [call])
    send!(state.socket, call)
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
    hello = Diode.self()

    send!(state.socket, [@hello, Object.encode!(hello), Chain.genesis_hash()])

    receive do
      {:ssl, _socket, msg} ->
        msg = decode(msg)

        case hd(msg) do
          @hello ->
            handle_msg(msg, state)

          _ ->
            :io.format("PeerHandler expected hello message, but got ~p~n", [msg])
            {:stop, :normal, state}
        end
    after
      3_000 ->
        :io.format("PeerHandler expected hello message, timeout~n")
        {:stop, :normal, state}
    end

    {:noreply, state}
  end

  def handle_info({:ssl, socket, omsg}, state) do
    msg = decode(omsg)

    # :io.format("Got message type ~p (~p bytes / ~p) ~n", [
    #   hd(msg),
    #   byte_size(omsg),
    #   byte_size(:erlang.term_to_binary(msg))
    # ])

    case handle_msg(msg, state) do
      {reply, state} when not is_atom(reply) ->
        # :io.format("PeerMsg: #{inspect(msg)} => #{inspect(reply)}~n")
        send!(socket, reply)
        {:noreply, state}

      other ->
        # :io.format("PeerMsg: #{inspect(msg)}~n")
        other
    end
  end

  def handle_info({:ssl_closed, _}, state) do
    :io.format("PeerHandler connection to ~p closed by remote.~n", [peer(state)])
    {:stop, :normal, state}
  end

  def handle_info(msg, state) do
    :io.format("PeerHandler unhandled info: ~180p~n", [msg])
    {:noreply, state}
  end

  defp handle_msg([@hello, server, genesis_hash], state) do
    genesis = Chain.genesis_hash()

    if genesis != genesis_hash do
      :io.format("Hello wrong genesis: ~p ~p~n", [
        Base16.encode(genesis),
        Base16.encode(genesis_hash)
      ])

      {:stop, :normal, state}
    else
      if Map.has_key?(state, :peer_port) do
        {:noreply, state}
      else
        # Todo: need connection abort when no hello after 5 sec
        server = Object.decode!(server)
        id = Wallet.address!(state.node_id)
        ^id = Object.key(server)

        port = Server.server_port(server)

        IO.puts("Received hello from: #{Wallet.printable(state.node_id)}")
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
    :io.format("Syncing ...~n")

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
                  :io.format("ignoring wrong ordered block from: ~p~n", [peer(state)])
                  blocks
                end
              end
          end

        {[@response, @publish, "missing_parent"], %{state | blocks: blocks}}

      %Chain.Block{} ->
        case Block.validate(block) do
          %Chain.Block{} = block ->
            Chain.add_block(block)

            # replay block backup list
            Enum.each(state.blocks, fn oldblock ->
              with %Chain.Block{} <- Block.parent(oldblock),
                   %Chain.Block{} = block <- Block.validate(oldblock) do
                Chain.add_block(block, false)
              end
            end)

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
        next = [%{block | receipts: []} | blocks]

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
        send!(state.socket, [@publish, parents])
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
    IO.puts("Unhandled: #{inspect(msg)}")
    {:noreply, state}
  end

  defp peer(state) do
    {state.peer_address, Map.get(state, :peer_port)}
  end

  defp respond(state, msg) do
    {{:value, {_call, from}}, calls} = :queue.out(state.calls)
    # :io.format("respond: ~p,#{inspect(msg)}~n", [{call, from}])
    if from != nil do
      :ok = GenServer.reply(from, msg)
    end

    {:noreply, %{state | calls: calls}}
  end

  defp send!(socket, data) do
    :ok = :ssl.send(socket, encode(data))
  end
end

# Diode Server
# Copyright 2021-2024 Diode
# Licensed under the Diode License, Version 1.1
defmodule Network.EdgeV2 do
  require Logger

  def handle_rpc(msg) do
    case msg do
      [cmd | _rest] when cmd in ["ping", "isonline", "sendtransaction"] ->
        handle_async_msg(msg)

      ["get" <> _ | _rest] ->
        handle_async_msg(msg)

      _ ->
        Logger.warning("EdgeV2 - Unhandled message: #{truncate(msg)}")
        error(401, "bad input")
    end
  end

  def handle_async_msg(msg) do
    case msg do
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
          |> CMerkleTree.root_hashes()
        end)
        |> response()

      ["getaccountroot", index, id] ->
        BlockProcess.with_block(to_num(index), fn block ->
          Chain.Block.state(block)
          |> Chain.State.account(id)
          |> case do
            nil ->
              error("account does not exist")

            %Chain.Account{} ->
              proof = Chain.Block.state_tree(block) |> CMerkleTree.get_proofs(id)
              root = CMerkleTree.root_hash(Chain.Block.account_tree(block, id))
              response(root, proof)
          end
        end)

      ["getaccount", index, id] ->
        BlockProcess.with_block(to_num(index), fn block ->
          if block == nil, do: check_block(to_num(index))

          Chain.Block.state(block)
          |> Chain.State.account(id)
          |> case do
            nil ->
              error("account does not exist")

            account = %Chain.Account{} ->
              proof =
                Chain.Block.state_tree(block)
                |> CMerkleTree.get_proofs(id)

              response(
                %{
                  nonce: account.nonce,
                  balance: account.balance,
                  storage_root: CMerkleTree.root_hash(Chain.Block.account_tree(block, id)),
                  code: Chain.Account.codehash(account)
                },
                proof
              )
          end
        end)

      ["getaccountroots", index, id] ->
        BlockProcess.with_account_tree(to_num(index), id, fn
          nil -> error("account does not exist")
          tree -> response(CMerkleTree.root_hashes(tree))
        end)

      ["getaccountvalue", index, id, key] ->
        BlockProcess.with_account_tree(to_num(index), id, fn
          nil -> error("account does not exist")
          tree -> response(CMerkleTree.get_proofs(tree, key))
        end)

      ["getaccountvalues", index, id | keys] ->
        BlockProcess.with_account_tree(to_num(index), id, fn
          nil ->
            error("account does not exist")

          tree ->
            response(
              Enum.map(keys, fn key ->
                CMerkleTree.get_proofs(tree, key)
              end)
            )
        end)

      ["sendtransaction", tx] ->
        # Testing transaction
        tx = Chain.Transaction.from_rlp(tx)

        err =
          Chain.with_peak(fn peak ->
            state = Chain.Block.state(peak) |> Chain.State.clone()

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
        Logger.warning("EdgeV2 - Unhandled message: #{truncate(msg)}")
        error(400, "that is not rlp")

      _ ->
        Logger.warning("EdgeV2 - Unhandled message: #{truncate(msg)}")
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
end

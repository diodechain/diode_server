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

  @doc """
  Finds the "optimal" provable sequence for the user's view. The view is defined by the counts of miners in the window.

  Let's assume the current block peak 100 and these miners:
  - Block | Miner
  - 100   | A
  - 99    | A
  - 98    | A
  - 97    | C
  - 96    | A
  - 95    | C
  - 94    | B
  - 93    | A
  - 92    | C
  - 91    | D
  - 90    | A
  """
  def find_sequence(counts, threshold, max_block) do
    # for the example let's assume counts is:
    # %{A => 10, B => 30, C => 20, D => 40}
    # and threshold is 50

    last_blocks =
      Model.ChainSql.query_last_blocks_by_miners(0, max_block, Map.keys(counts))
      |> Enum.sort_by(fn {number, _miner} -> number end, :desc)

    # query_last_blocks_by_miners returns a list of {number, miner} tuples of the last blocks mined by each miner:
    # so in above example, it will return:
    # [{100, A}, {97, C}, {94, B}, {91, D}]

    Enum.reduce_while(last_blocks, 0, fn {number, miner}, score ->
      score = score + Map.fetch!(counts, miner)

      if score > threshold do
        {:halt, {:ok, number}}
      else
        {:cont, score}
      end
    end)
    |> case do
      {:ok, last_block} ->
        # This will return block 94, because A=10+B=30+C=20>50
        # But 94...100 is not the shortest sequence for A+B+C>=
        # Instead the shortest sequence is [94,95,96]
        # To find this we know search forward from 94 until we find a sequence that satisfies the condition
        first_block = find_sequence_forward(last_block, max_block, counts, threshold)
        {:ok, Enum.to_list(last_block..first_block)}

      _ ->
        raise "sequence not found"
    end
  end

  def find_sequence_forward(min_block, max_block, counts, threshold) do
    Model.ChainSql.query_last_blocks_by_miners_forward(min_block, max_block, Map.keys(counts))
    |> Enum.sort_by(fn {number, _miner} -> number end, :asc)
    |> Enum.reduce_while(0, fn {number, miner}, score ->
      score = score + Map.fetch!(counts, miner)

      if score > threshold do
        {:halt, {:ok, number}}
      else
        {:cont, score}
      end
    end)
    |> case do
      {:ok, first_block} -> first_block
      _ -> raise "sequence not found"
    end
  end

  def get_counts(last_block, window_size) do
    window = get_blockquick_window(last_block, window_size)
    Enum.reduce(window, %{}, fn miner, acc -> Map.update(acc, miner, 1, &(&1 + 1)) end)
  end

  def get_blockquick_seq(last_block, window_size) do
    # Step 1: Identifying current view the device has
    #   based on it's current last valid block number
    counts = get_counts(last_block, window_size)
    threshold = div(window_size, 2)

    max_block =
      if window_size > 100 do
        # old cli clients do not accept the most recent peaks, so we have to provide older
        # provable blocks
        Chain.peak() - (window_size - 100)
      else
        Chain.peak()
      end

    # Step 2: Find a provable sequence
    #    Iterating from peak backwards until the block score is over 50% of the window_size
    {:ok, provable_range} = find_sequence(counts, threshold, max_block)

    # Step 3: Based on last provable sequence, find the next sequence
    next_candidate = hd(provable_range)
    prefix = Enum.to_list((next_candidate - window_size)..(next_candidate - 1))

    if next_candidate == last_block do
      prefix ++ provable_range
    else
      prefix ++ provable_range ++ get_blockquick_seq(next_candidate, window_size)
    end
    |> Enum.uniq()
    |> Enum.sort()
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

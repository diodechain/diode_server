# Diode Server
# Copyright 2021-2024 Diode
# Licensed under the Diode License, Version 1.1
defmodule RemoteChain.Edge do
  import Network.EdgeV2, only: [response: 1, response: 2, error: 1]
  require Logger

  def handle_async_msg(chain, msg, state) do
    case msg do
      ["getblockpeak"] ->
        RemoteChain.peaknumber(chain)
        |> response()

      ["getblock", index] when is_binary(index) ->
        error("not implemented")

      ["getblockheader", index] when is_binary(index) ->
        %{
          "hash" => hash,
          "nonce" => nonce,
          "miner" => miner,
          "number" => number,
          "parentHash" => previous_block,
          "stateRoot" => state_hash,
          "timestamp" => timestamp,
          "transactionsRoot" => transaction_hash
        } = RemoteChain.RPCCache.get_block_by_number(chain, hex_blockref(index))

        response(%{
          "block_hash" => Base16.decode(hash),
          "miner" => Base16.decode(miner),
          "miner_signature" => nil,
          "nonce" => Base16.decode(nonce),
          "number" => Base16.decode(number),
          "previous_block" => Base16.decode(previous_block),
          "state_hash" => Base16.decode(state_hash),
          "timestamp" => Base16.decode(timestamp),
          "transaction_hash" => Base16.decode(transaction_hash)
        })

      ["getblockheader2", index] when is_binary(index) ->
        error("not implemented")

      ["getblockquick", last_block, window_size]
      when is_binary(last_block) and
             is_binary(window_size) ->
        error("not implemented")

      ["getblockquick2", last_block, window_size]
      when is_binary(last_block) and
             is_binary(window_size) ->
        error("not implemented")

      ["getstateroots", _index] ->
        error("not implemented")

      ["getaccount", block, address] ->
        # requires https://eips.ethereum.org/EIPS/eip-1186
        # response(Moonbeam.proof(address, [0], blockref(block)))

        code =
          RemoteChain.RPCCache.get_code(chain, hex_address(address), hex_blockref(block))
          |> Base16.decode()

        storage_root =
          if code == "" do
            ""
          else
            RemoteChain.RPCCache.get_account_root(
              chain,
              hex_address(address),
              hex_blockref(block)
            )
            |> Base16.decode()
          end

        response(%{
          nonce:
            RemoteChain.RPCCache.get_transaction_count(
              chain,
              hex_address(address),
              hex_blockref(block)
            )
            |> Base16.decode(),
          balance:
            RemoteChain.RPCCache.get_balance(chain, hex_address(address), hex_blockref(block))
            |> Base16.decode(),
          storage_root: storage_root,
          code: Hash.keccak_256(code)
        })

      ["getaccountroots", _index, _id] ->
        error("not implemented")

      ["getaccountvalue", block, address, key] ->
        # requires https://eips.ethereum.org/EIPS/eip-1186
        # response(Moonbeam.proof(address, [key], blockref(block)))
        RemoteChain.RPCCache.get_storage_at(
          chain,
          hex_address(address),
          hex_slot(key),
          hex_blockref(block)
        )
        |> Base16.decode()
        |> response()

      ["getaccountvalues", block, address | keys] ->
        # requires https://eips.ethereum.org/EIPS/eip-1186
        # response(Moonbeam.proof(address, keys, blockref(block)))
        RemoteChain.RPCCache.get_storage_many(
          chain,
          hex_address(address),
          Enum.map(keys, &hex_slot/1),
          hex_blockref(block)
        )
        |> Enum.map(&Base16.decode/1)
        |> response()

      ["sendtransaction", payload] ->
        case RemoteChain.RPC.send_raw_transaction(chain, Base16.encode(payload)) do
          :already_known -> response("ok")
          tx_hash when is_binary(tx_hash) -> response("ok")
          {:error, error} -> error(error)
        end

      ["getmetanonce", block, address] ->
        CallPermit.rpc_call!(chain, CallPermit.nonces(address), nil, hex_blockref(block))
        |> Base16.decode_int()
        |> response()

      ["sendmetatransaction", tx] ->
        # These are CallPermit metatransactions
        # Testing transaction
        [from, to, value, call, gaslimit, deadline, v, r, s] = Rlp.decode!(tx)
        value = Rlpx.bin2num(value)
        gaslimit = Rlpx.bin2num(gaslimit)
        deadline = Rlpx.bin2num(deadline)
        v = Rlpx.bin2num(v)
        r = Rlpx.bin2num(r)
        s = Rlpx.bin2num(s)

        call = CallPermit.dispatch(from, to, value, call, gaslimit, deadline, v, r, s)
        gas_price = RemoteChain.RPC.gas_price(chain) |> Base16.decode_int()
        nonce = RemoteChain.NonceProvider.nonce(chain)

        # Can't do this pre-check always because we will be receiving batches of future nonces
        # those are not yet valid but will be valid in the future, after the other txs have
        # been processed...
        if nonce == RemoteChain.NonceProvider.fetch_nonce(chain) do
          spawn(fn ->
            CallPermit.rpc_call(chain, call, Wallet.address!(CallPermit.wallet()))
            |> case do
              {:ok, _} -> :ok
              error -> Logger.error("RTX rpc_call failed: #{inspect(error)}")
            end
          end)
        end

        tx =
          Shell.raw(CallPermit.wallet(), call,
            to: CallPermit.address(),
            chainId: chain.chain_id(),
            gas: 12_000_000,
            gasPrice: gas_price + div(gas_price, 10),
            value: 0,
            nonce: nonce
          )

        payload =
          tx
          |> Chain.Transaction.to_rlp()
          |> Rlp.encode!()
          |> Base16.encode()

        tx_hash =
          Chain.Transaction.hash(tx)
          |> Base16.encode()

        Logger.info("Submitting RTX: #{tx_hash} (#{inspect(tx)})")
        # We're pushing to the TxRelay keep alive server to ensure the TX
        # is broadcasted even if the RPC connection goes down in the next call.
        # This is so to preserve the nonce ordering if at all possible
        RemoteChain.TxRelay.keep_alive(chain, tx, payload)

        # In order to ensure delivery we're broadcasting to all known endpoints of this chain
        spawn(fn ->
          RemoteChain.RPC.send_raw_transaction(chain, payload)

          for endpoint <- Enum.shuffle(chain.rpc_endpoints()) do
            RemoteChain.HTTP.send_raw_transaction(endpoint, payload)
          end
        end)

        response("ok", tx_hash)

      _ ->
        default(msg, state)
    end
  end

  defp default(msg, state) do
    Network.EdgeV2.handle_async_msg(msg, state)
  end

  defp hex_blockref(ref) when ref in ["latest", "earliest"], do: ref

  defp hex_blockref(ref) do
    case Base16.encode(ref) do
      "0x" -> "0x0"
      "0x0" <> rest -> "0x" <> rest
      other -> other
    end
  end

  defp hex_address(<<_::binary-size(20)>> = address) do
    Base16.encode(address)
  end

  defp hex_slot(<<_::binary-size(32)>> = key) do
    Base16.encode(key)
  end

  defp hex_slot(key) when is_binary(key) do
    Base16.encode(Rlpx.bin2num(key), false)
  end
end

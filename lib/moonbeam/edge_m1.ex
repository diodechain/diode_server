# Diode Server
# Copyright 2023 Diode
# Licensed under the Diode License, Version 1.1
defmodule Network.EdgeM1 do
  import Network.EdgeV2, only: [response: 1, response: 2, error: 1]

  def handle_async_msg(msg, state) do
    case msg do
      ["getblockpeak"] ->
        Moonbeam.block_number()
        |> Base16.decode()
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
        } = Moonbeam.get_block_by_number(hex_blockref(index))

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

        code = Base16.decode(Moonbeam.get_code(hex_address(address), hex_blockref(block)))

        storage_root =
          if code == "" do
            ""
          else
            Hash.keccak_256("#{div(System.os_time(:second), 10)}")
          end

        response(%{
          nonce:
            Base16.decode(
              Moonbeam.get_transaction_count(hex_address(address), hex_blockref(block))
            ),
          balance: Base16.decode(Moonbeam.get_balance(hex_address(address), hex_blockref(block))),
          storage_root: storage_root,
          code: Hash.keccak_256(code)
        })

      ["getaccountroots", _index, _id] ->
        error("not implemented")

      ["getaccountvalue", block, address, key] ->
        # requires https://eips.ethereum.org/EIPS/eip-1186
        # response(Moonbeam.proof(address, [key], blockref(block)))
        Moonbeam.get_storage_at(hex_address(address), hex_key(key), hex_blockref(block))
        |> Base16.decode()
        |> response()

      ["getaccountvalues", block, address | keys] ->
        # requires https://eips.ethereum.org/EIPS/eip-1186
        # response(Moonbeam.proof(address, keys, blockref(block)))
        Enum.map(keys, fn key ->
          Moonbeam.get_storage_at(hex_address(address), hex_key(key), hex_blockref(block))
          |> Base16.decode()
        end)
        |> response()

      ["sendtransaction", _tx] ->
        error("not implemented")

      ["getmetanonce", block, address] ->
        CallPermit.nonces(address)
        |> CallPermit.rpc_call!(nil, hex_blockref(block))
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

        nonce = Moonbeam.NonceProvider.nonce()
        # Can't do this pre-check because we will be receiving batches of future nonces
        # those are not yet valid but will be valid in the future, after the other txs have
        # been processed...
        if nonce == Moonbeam.NonceProvider.fetch_nonce() do
          {:ok, _} = CallPermit.rpc_call(call, Wallet.address!(CallPermit.wallet()))
        end

        # Moonbeam.estimate_gas(Base16.encode(CallPermit.address()), Base16.encode(call))
        # |> IO.inspect(label: "estimate_gas")
        # {:error, %{"message" => error}} ->
        #   error(error)

        tx =
          Shell.raw(CallPermit.wallet(), call,
            to: CallPermit.address(),
            chainId: Moonbeam.chain_id(),
            gas: 12_000_000,
            gasPrice: Base16.decode(Moonbeam.gas_price()),
            value: 0,
            nonce: nonce
          )

        payload =
          tx
          |> Chain.Transaction.to_rlp()
          |> Rlp.encode!()
          |> Base16.encode()

        tx_hash =
          Chain.Transaction.to_rlp(tx)
          |> Rlp.encode!()
          |> Hash.keccak_256()
          |> Base16.encode()

        case Moonbeam.send_raw_transaction(payload) do
          ^tx_hash -> response("ok", tx_hash)
          :already_known -> response("ok", tx_hash)
        end

      _ ->
        default(msg, state)
    end
  end

  defp default(msg, state) do
    Network.EdgeV2.handle_async_msg(msg, state)
  end

  defp hex_blockref(ref) when ref in ["latest", "earliest"], do: ref
  defp hex_blockref(ref), do: Base16.encode(ref)

  defp hex_address(<<_::binary-size(20)>> = address) do
    Base16.encode(address)
  end

  defp hex_key(<<_::binary-size(32)>> = key) do
    Base16.encode(key)
  end
end

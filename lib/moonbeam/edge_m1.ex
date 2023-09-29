# Diode Server
# Copyright 2023 Diode
# Licensed under the Diode License, Version 1.1
defmodule Network.EdgeM1 do
  import Network.EdgeV2, only: [response: 1, error: 1]

  def handle_async_msg(msg, state) do
    case msg do
      ["getblockpeak"] ->
        response(Moonbeam.block_number())

      ["getblock", index] when is_binary(index) ->
        error("not implemented")

      ["getblockheader", index] when is_binary(index) ->
        response(Moonbeam.get_block_by_number(index))

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

        response(%{
          nonce: Moonbeam.get_transaction_count(hex_address(address), hex_blockref(block)),
          balance: Moonbeam.get_balance(hex_address(address), hex_blockref(block)),
          storage_root: nil,
          code: nil
        })

      ["getaccountroots", _index, _id] ->
        error("not implemented")

      ["getaccountvalue", _block, _address, _key] ->
        # requires https://eips.ethereum.org/EIPS/eip-1186
        # response(Moonbeam.proof(address, [key], blockref(block)))
        error("not implemented")

      ["getaccountvalues", _block, _address | _keys] ->
        # requires https://eips.ethereum.org/EIPS/eip-1186
        # response(Moonbeam.proof(address, keys, blockref(block)))
        error("not implemented")

      ["sendtransaction", tx] ->
        # These are CallPermit metatransactions
        # Testing transaction
        [from, to, value, call, gaslimit, deadline, v, r, s] = Rlp.decode!(tx)
        call = CallPermit.dispatch(from, to, value, call, gaslimit, deadline, v, r, s)
        response(Moonbeam.call!(call))

      _ ->
        default(msg, state)
    end
  end

  defp default(msg, state) do
    Network.EdgeV2.handle_async_msg(msg, state)
  end

  defp hex_blockref(ref) when ref in ["latest", "earliest"], do: ref
  defp hex_blockref("0x" <> _rest = hex), do: hex
  defp hex_blockref(n) when is_integer(n), do: Base16.encode(n, false)
  defp hex_blockref(_other), do: throw(:notfound)

  defp hex_address(<<_::binary-size(20)>> = address) do
    Base16.encode(address)
  end
end

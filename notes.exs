# 9th May 2024

node = :global.whereis_name({RemoteChain.NodeProxy, Chains.Moonbeam})
Process.info(node)
:sys.get_state(node)

cache = :global.whereis_name({RemoteChain.RPCCache, Chains.Moonbeam})
Process.info(cache)
Lru.size(:sys.get_state(cache).lru)


# 16 Apr 2024

dom = "0x5849ea89593cf65e13110690d9339c121801a45c"
bns = "0x8A093E3A83F63A00FFFC4729AA55482845A49294"
RemoteChain.RPCCache.get_account_root(Chains.Moonbeam, bns)

# 30 Apr 2024
r ABI
chain_id = 1284
bridge = 0xA32A9ED71FBF22E6D197C13725AD61958E9A4499
bridge_out_native = Base16.decode("0x2C303A315A1EE4C377E28121BAF30146E229731B")

{len, _gas} = Shell.call(bridge_out_native, "txsLength", ["uint256"], [chain_id])
len = :binary.decode_unsigned(len)

{tx, _gas} = Shell.call(bridge_out_native, "txsAt", ["uint256", "uint256"], [chain_id, len - 1])
[sender, destination, amount, timestamp, _blockNumber, historyHash] = ABI.decode_types(["address", "address", "uint256", "uint256", "uint256", "bytes32"], tx)

sig =
Secp256k1.sign(Wallet.privkey!(Diode.miner()), historyHash, :none) |> Secp256k1.bitcoin_to_rlp()

add_witness =
ABI.encode_call("addInWitness", ["bytes32", "uint8", "bytes32", "bytes32"], [
    historyHash | sig
])

gas_price = RemoteChain.RPC.gas_price(chain_id) |> Base16.decode_int()
nonce = RemoteChain.NonceProvider.nonce(chain_id)

tx =
    Shell.raw(CallPermit.wallet(), add_witness,
      to: bridge,
      chainId: chain_id,
      gas: 12_000_000,
      gasPrice: gas_price + div(gas_price, 10),
      value: 0,
      nonce: nonce
    )
  payload = tx |> Chain.Transaction.to_rlp() |> Rlp.encode!() |> Base16.encode()
  tx_hash = Chain.Transaction.hash(tx) |> Base16.encode()
  RemoteChain.TxRelay.keep_alive(chain_id, tx, payload)
    RemoteChain.RPC.send_raw_transaction(chain_id, payload)
    for endpoint <- RemoteChain.chainimpl(chain_id).rpc_endpoints() do
      RemoteChain.HTTP.send_raw_transaction(endpoint, payload)
    end

# 23rd Jul 2024

registry = Hash.to_address(0x5000000000000000000000000000000000000000)
eu1 = Hash.to_address(0x937c492a77ae90de971986d003ffbc5f8bb2232c)

block = Chain.peak()
accs = BlockProcess.with_state(block, fn state -> Chain.State.accounts(state) end) |> Enum.sort()

fp = File.open!("accounts.csv", [:write])
for {key, acc} <- accs do
  balance = Chain.Account.balance(acc)
  {m_staked, m_unstaked} = Contract.Registry.miner_value_slot(key, block)
  {c_staked, c_unstaked} = Contract.Registry.contract_value_slot(key, block)
  if balance > 0 or m_staked > 0 or m_unstaked > 0 or c_staked > 0 or c_unstaked > 0 do
    IO.puts("#{Base16.encode(key)} #{balance} #{m_staked} #{m_unstaked} #{c_staked} #{c_unstaked}")
    IO.puts(fp, "#{Base16.encode(key)} #{balance} #{m_staked} #{m_unstaked} #{c_staked} #{c_unstaked}")
  end
end
File.close(fp)

# 22nd Jul 2024

Network.Rpc.handle_jsonrpc(%{"id" => 0, "method" => "eth_getTransactionByHash", "params" => ["0xc453a09ce1943f769341fe9dbcd3cb012d549753f812e6f8da47ab3a286a96ce"]})


RemoteChain.RPC.get_transaction_by_hash(Chains.Diode, "0xc453a09ce1943f769341fe9dbcd3cb012d549753f812e6f8da47ab3a286a96ce")


# 19th Jul 2024
# eu1

6808835 Unstake
6808836

6984035 Unstake Done
6984036

epoch = 40320

stake = fn address, block ->
  for x <- 0..3 do
    {v1, _gas} =
      Shell.call(Diode.registry_address(), "MinerValue", ["uint8", "address"], [x, address], blockRef: block)
    :binary.decode_unsigned(v1)
  end
end

w = Diode.miner()

find_stake = fn x, y ->
  stake.(w, x)
end


balance = fn address, block ->
  BlockProcess.with_state(block, fn state ->
    Chain.State.ensure_account(state, address)
    |> Chain.Account.balance()
  end)
end

peak = Chain.peak # 7587652
for x <- 6757..7587 do
  b = balance.(Diode.miner(), x*1000)
  if b > 0 do
    IO.puts("#{x} = #{b}")
  end
end

# 22nd May 2024


step = 1000
range = Range.new(7290000, Chain.peak(), step)
for x <- range do
  max = min(x + step, Chain.peak())
  ret = Model.Sql.query!(Db.Default, "SELECT parent, hash, number FROM blocks WHERE number >= ?1 AND number < ?2 ORDER BY number", bind: [x, max])
  should = x..(max - 1) |> MapSet.new()
  have = Enum.map(ret, fn [parent: _, hash: _, number: number] -> number end) |> MapSet.new()
  IO.puts("#{x} Length: #{length(ret)} / #{max - x}: #{inspect MapSet.difference(should, have)}")

  for x <- Enum.sort(MapSet.difference(should, have), :desc) do
    [x_hash] = BlockProcess.fetch(x + 1, [:parent_hash])
    [^x] = BlockProcess.fetch(x_hash, [:number])
    Model.ChainSql.put_block_number(x_hash)
  end

end

# 10th May 2024

bns = 0xaf60faa5cd840b724742f1af116168276112d6a6
{acc, nr} = Chain.with_peak(fn block -> {Chain.Block.state(block) |> Chain.State.ensure_account(
bns), Chain.Block.number(block)} end)
File.write!("bns_account_#{nr}.etf", :erlang.term_to_binary(acc))

Logger.configure(level: :warning)

accs = ~w(bns_account_7144000.etf bns_account_7144224.etf bns_account_7144861.etf
  bns_account_7145072.etf bns_account_7145706.etf) |> Enum.map(&File.read!(&1) |> :erlang.binary_to_term() |> Map.put(:root_hash, nil))

check = fn acc ->
  {time1, root1} = :timer.tc(fn -> MerkleTree.copy(Chain.Account.tree(acc), MerkleTree2) |> MerkleTree.root_hash() end)
  {time2, root2} = :timer.tc(fn -> Chain.Account.root_hash(acc) end)
  ^root1 = root2
  {div(time1, 1000), div(time2, 1000), time1 / time2}
end

check2 = fn acc ->
  {time1, root1} = :timer.tc(fn -> MerkleTree.copy(Chain.Account.tree(acc), MerkleTree2) |> MerkleTree.root_hash() end)
  {time2, root2} = :timer.tc(fn -> MerkleCache.root_hash(Chain.Account.tree(acc)) end)
  ^root1 = root2
  {div(time1, 1000), div(time2, 1000), time1 / time2}
end

check_diff = fn acc, acc2 ->
  {time1, diff1} = :timer.tc(fn -> MerkleTree.difference(Chain.Account.tree(acc), Chain.Account.tree(acc2)) end)
  {time2, diff2} = :timer.tc(fn -> MerkleCache.difference(Chain.Account.tree(acc), Chain.Account.tree(acc2)) end)
  ^diff1 = diff2
  {div(time1, 1000), div(time2, 1000), time1 / time2}
end

:timer.tc(fn -> Chain.Account.root_hash(hd(accs)) end)
:timer.tc(fn -> Chain.Account.root_hash(Enum.at(accs, 1)) end)

check.(Enum.at(accs, 1))
check2.(Enum.at(accs, 1))
check_diff.(Enum.at(accs, 1), Enum.at(accs, 2))
check_diff.(Enum.at(accs, 1), Enum.at(accs, 1))
check_diff.(Enum.at(accs, 2), Enum.at(accs, 1))

loop = fn loop, acc ->
  Chain.Account.root_hash(acc)
  loop.(loop, acc)
end

pid = spawn(fn -> loop.(loop, Enum.at(accs, 1)) end)
spawn(fn -> Profiler.fprof(MerkleCache) end)


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

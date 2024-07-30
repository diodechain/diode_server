# 29th Jul 2024

prev_state = BlockProcess.with_state(7506000, fn prev_state -> prev_state end)
b = File.read!("block_false_7506001") |> :erlang.binary_to_term()
g = File.read!("block_true_7506001") |> :erlang.binary_to_term()
good_hash = Chain.Block.state_hash(g)

test = fn block ->
  new_state = Chain.Block.simulate(block) |> Chain.Block.state()
  delta = Chain.State.difference(prev_state, new_state)
  new_state2 = Chain.State.apply_difference(prev_state, delta)
    |> Chain.State.normalize()
    |> Chain.State.compact()
    |> BertInt.encode!()
    |> BertInt.decode!()

  MerkleTree.root_hash(Chain.State.tree(new_state2)) == good_hash
end



b_state = Chain.Block.state(b)
g_state = Chain.Block.state(g)


BlockProcess.with_state(Chain.Block.number(file) - 1, fn prev_state ->
  state = Chain.Block.state(file)
  IO.inspect({state, prev_state})
  diff = Chain.State.difference(prev_state, state)
  IO.inspect(diff)
  ret = Chain.State.apply_difference(prev_state, diff)
  IO.inspect(ret)
end)

check = fn state ->
  state2 = %{state | hash: nil, accounts: Enum.map(state.accounts, fn {key, acc} -> {key, %{acc | root_hash: nil}} end) |> Map.new()} |> Map.delete(:store)
  {MerkleTree.root_hash(Chain.State.tree(state)), Chain.State.hash(state2)}
end

# 26th Jul 2024

Setting 7506000 (0x00004263f49ab73418a8e6f282a116c6f733b324ed0ac6f6fd0c0d3aa215b02b)

BlockProcess.with_block(7505999, fn block -> {Chain.Block.state_hash(block), block.header.state_hash, MerkleTree.root_hash(Chain.State.tree(Chain.Block.state(block)))} end)
BlockProcess.with_block(7506000, fn block ->
  state = Chain.Block.state(block)
  state2 = %{state | hash: nil, accounts: Enum.map(state.accounts, fn {key, acc} -> {key, %{acc | root_hash: nil}} end) |> Map.new()} |> Map.delete(:store)
  {block.header.state_hash, MerkleTree.root_hash(Chain.State.tree(state)), Chain.State.hash(state2)}
end)


# 25th Jul 2024

crash_tx = Base16.decode("0x836c00000001740000000a64000a5f5f7374727563745f5f640018456c697869722e436861696e2e5472616e73616374696f6e640008636861696e5f6964610f640004646174616d000000449854175f000000000000000000000000870a2d53b5bff90e35099b04509627b7741b446a00000000000000000000000000000000000000000000000000000000000005046400086761734c696d69746201312d0064000867617350726963656100640004696e69746400036e696c6400056e6f6e636561166400097369676e61747572656d00000041006ae1a25d22adad034618ba162f17d05a60ef92c2df2d1fbc9192a6ea2797bd761617100a9c969ea9c863b4ea8c16769f36e0e0c214d418c0fdca005262bdcbea640002746f6d000000142c303a315a1ee4c377e28121baf30146e229731b64000576616c75656e0900000090ac6e327886876a") |> :erlang.binary_to_term |> hd
Chain.Worker.build_block("latest", [crash_tx], Diode.miner())
Chain.Transaction.value(crash_tx)

faucet1 = Base16.decode("0xbada81fae68925fec725790c34b68b5faca90d45")
bridge = Base16.decode("0x2c303a315a1ee4c377e28121baf30146e229731b")
bridgeimpl = Base16.decode("0xd0C5ec4bC1b0D36e3eeA8098aCE2209dCEbA136a")

Chain.with_peak_state(fn state ->
  Chain.State.ensure_account(state, faucet1)
  |> Chain.Account.balance()
end)

Shell.get_balance(bridge)
Shell.get_balance(bridgeimpl)

balance = 3787599979000000000006
value = 2500000000000000000000

** (ArgumentError) errors were found at the given arguments:

  * 1st argument: out of range

    (stdlib 4.3) :binary.encode_unsigned(-1212400020999999999994)
    (Elixir.Diode 1.5.0) lib/rlp.ex:71: Rlp.do_encode!/1
    (Elixir.Diode 1.5.0) lib/rlp.ex:19: Rlp.encode!/1
    (elixir 1.15.7) lib/enum.ex:1693: Enum."-map/2-lists^map/1-1-"/2
    (elixir 1.15.7) lib/enum.ex:1693: Enum."-map/2-lists^map/1-1-"/2
    (Elixir.Diode 1.5.0) lib/rlp.ex:15: Rlp.encode!/1
    (Elixir.Diode 1.5.0) lib/chain/account.ex:100: Chain.Account.hash/1
    (Elixir.Diode 1.5.0) lib/chain/state.ex:72: Chain.State.hash_accounts/1
    (Elixir.Diode 1.5.0) lib/chain/state.ex:72: Chain.State.hash_accounts/1
    (Elixir.Diode 1.5.0) lib/chain/state.ex:67: Chain.State.do_tree/2
    (Elixir.Diode 1.5.0) lib/chain/state.ex:38: Chain.State.normalize/1
    (stdlib 4.3) timer.erl:235: :timer.tc/1
    (Elixir.Diode 1.5.0) lib/stats.ex:44: Stats.tc!/2
    (Elixir.Diode 1.5.0) lib/stats.ex:35: Stats.tc/2
    (Elixir.Diode 1.5.0) lib/chain/block.ex:385: anonymous fn/1 in Chain.Block.finalize_header/2
    (stdlib 4.3) timer.erl:235: :timer.tc/1
    (Elixir.Diode 1.5.0) lib/stats.ex:44: Stats.tc!/2
    (Elixir.Diode 1.5.0) lib/stats.ex:35: Stats.tc/2
    (Elixir.Diode 1.5.0) lib/chain/worker.ex:422: Chain.Worker.build_block/4




# 23rd Jul 2024

File.read!("transactions_7615069.csv") |> String.split("\n", trim: true) |> Enum.reduce(%{}, fn row, map ->
  [block, from, to, _value] = String.split(row, " ", trim: true)
  if "0x5000000000000000000000000000000000000000" in [from, to] do
    map
  else
    {map, from} = case Map.get(map, from) do
      nil -> {Map.put(map, from, "BASE"), from}
      other -> {map, other}
    end

    if from == to do
      Map.delete(map, to)
    else
      Map.put(map, to, from)
    end
  end
end)


# 23rd Jul 2024

block = Chain.peak()
fp = File.open!("transactions_#{block}.csv", [:write])
for x <- 7429432..block do
  txs = BlockProcess.with_block(x, fn block -> Chain.Block.transactions(block) |> Enum.filter(fn tx -> Chain.Transaction.value(tx) > 0 end) |> Enum.map(fn tx -> {Chain.Transaction.from(tx), Chain.Transaction.to(tx), Chain.Transaction.value(tx)} end) end)
  for {from, to, value} <- txs do
    log = "#{x} #{Base16.encode(from)} #{Base16.encode(to)} #{value}"
    IO.puts(fp, log)
    IO.puts(log)
  end
end
File.close(fp)



# 23rd Jul 2024

names = ~w(
BURNED 0x5000000000000000000000000000000000000000
US1 0xceca2f8cf1983b4cf0c1ba51fd382c2bc37aba58
EU1 0x937c492a77ae90de971986d003ffbc5f8bb2232c
AS1 0x68e0bafdda9ef323f692fc080d612718c941d120
Foundation_Multisig 0x1000000000000000000000000000000000000000
BURNED 0x000000000000000000000000000000000000dead
BURNED 0x0000000000000000000000000000000000000000
Foundation_Accountant  0x96cde043e986040cb13ffafd80eb8ceac196fb84
Foundation_Faucet_2 0x34e3961098de3348b465cc82791bd0f7ebce3ecd
Foundation_Faucet_3 0xc0c416b326133d74335e6828d558efe315bd597e
Foundation_Faucet_5 0x45aa0730cf4216f7195fc1f5903a171a1faa5209
Foundation_Faucet_1 0xbada81fae68925fec725790c34b68b5faca90d45
Foundation_Faucet_4 0x58cc80f5526594f07f33fd4be4aef153bab602b2
EU2 0xae699211c62156b8f29ce17be47d2f069a27f2a6
AS2 0x1350d3b501d6842ed881b59de4b95b27372bfae8
US2 0x7e4cd38d266902444dc9c8f7c0aa716a32497d0b
AS3 0xefbb6a0100e7df2f6e668f2f9e6551ece12b6f01
) |> Enum.chunk_every(2) |> Enum.map(fn [name, address] -> {Base16.decode(address), name} end) |> Map.new()

fmt = fn x ->
  x
  |> Integer.to_char_list
  |> Enum.reverse
  |> Enum.chunk_every(3)
  |> Enum.join(",")
  |> String.reverse
end

block = Chain.peak()
accs = BlockProcess.with_state(block, fn state -> Chain.State.accounts(state) end)

fp = File.open!("accounts_#{block}.csv", [:write])
log = "Name Address TotalDiode BalanceWei MinerStakedWei MinerUnstakedWei ContractStakedWei ContractUnstakedWei"
IO.puts(log)
IO.puts(fp, log)
for {key, acc} <- accs do
  name = names[key] || "_"
  balance = Chain.Account.balance(acc)
  {m_staked, m_unstaked} = Contract.Registry.miner_value_slot(key, block)
  {c_staked, c_unstaked} = Contract.Registry.contract_value_slot(key, block)
  if balance > 0 or m_staked > 0 or m_unstaked > 0 or c_staked > 0 or c_unstaked > 0 do
    total = div(balance + m_staked + m_unstaked + c_staked + c_unstaked, 1000000000000000000)
    log = "#{name} #{Base16.encode(key)} #{fmt.(total)} #{fmt.(balance)} #{fmt.(m_staked)} #{fmt.(m_unstaked)} #{fmt.(c_staked)} #{fmt.(c_unstaked)}"
    IO.puts(log)
    IO.puts(fp, log)
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

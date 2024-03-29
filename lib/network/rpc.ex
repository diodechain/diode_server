# Diode Server
# Copyright 2021 Diode
# Licensed under the Diode License, Version 1.1
defmodule Network.Rpc do
  alias Chain.BlockCache, as: Block
  alias Chain.{Account, Transaction, State}
  alias Model.ChainSql

  def handle_jsonrpc(rpcs, opts \\ [])

  def handle_jsonrpc(%{"_json" => rpcs}, opts) when is_list(rpcs) do
    handle_jsonrpc(rpcs, opts)
  end

  def handle_jsonrpc(rpcs, opts) when is_list(rpcs) do
    [head | rest] = Enum.chunk_every(rpcs, 100)

    tasks =
      Enum.map(rest, fn rpcs ->
        Task.async(fn ->
          Enum.map(rpcs, fn rpc ->
            {_status, body} = handle_jsonrpc(rpc, opts)
            body
          end)
        end)
      end)

    head_body =
      Enum.map(head, fn rpc ->
        {_status, body} = handle_jsonrpc(rpc, opts)
        body
      end)

    rest_body =
      Enum.flat_map(tasks, fn taskref ->
        Task.await(taskref, :infinity)
      end)

    {200, head_body ++ rest_body}
  end

  def handle_jsonrpc(body_params, opts) when is_map(body_params) do
    # :io.format("handle_jsonrpc: ~p~n", [body_params])

    {id, method} =
      case body_params do
        %{"method" => method, "id" => id} -> {id, method}
        %{"id" => id} -> {id, ""}
        _other -> {0, ""}
      end

    params = Map.get(body_params, "params", [])

    {result, code, error} =
      try do
        execute_rpc(method, params, opts)
      rescue
        e in ErlangError ->
          :io.format("Network.Rpc: ErlangError ~p in ~p: ~0p~n", [
            e,
            {method, params},
            __STACKTRACE__
          ])

          {nil, 400, %{"message" => "Bad Request"}}
      catch
        :notfound -> {nil, 404, %{"message" => "Not found"}}
        :badrequest -> {nil, 400, %{"message" => "Bad request"}}
      end

    if Diode.dev_mode?() do
      :io.format("~s = ~p~n", [method, result])
    end

    {ret, code} =
      if error == nil do
        if not is_map(result) or not Map.has_key?(result, "error") do
          {%{"result" => result}, code}
        else
          {result, code}
        end
      else
        code = if code == 200, do: 400, else: code
        {error, code}
      end

    envelope =
      %{"id" => {:raw, id}, "jsonrpc" => "2.0"}
      |> Map.merge(ret)
      |> Json.prepare!(big_x: false)

    {code, envelope}
  end

  defp execute([{true, {mod, fun}} | rest], args) do
    case apply(mod, fun, args) do
      nil -> execute(rest, args)
      other -> other
    end
  end

  defp execute([_ | rest], args) do
    execute(rest, args)
  end

  defp execute([], [method, params]) do
    :io.format("Unhandled: ~p ~p~n", [method, params])
    result("what method?", 422)
  end

  def execute_rpc("", _params, _opts) do
    throw(:badrequest)
  end

  def execute_rpc(method, params, opts) do
    apis = [
      {true, {__MODULE__, :execute_std}},
      {true, {__MODULE__, :execute_dio}},
      {Diode.dev_mode?(), {__MODULE__, :execute_dev}},
      {opts[:private], {__MODULE__, :execute_private}},
      {is_tuple(opts[:extra]), opts[:extra]}
    ]

    execute(apis, [method, params])
  end

  def execute_std(method, params) do
    case method do
      "net_peerCount" ->
        peers = Network.Server.get_connections(Network.PeerHandler)
        result(map_size(peers))

      "net_edgeCount" ->
        peers =
          map_size(Network.Server.get_connections(Network.EdgeV1)) +
            map_size(Network.Server.get_connections(Network.EdgeV2))

        result(peers)

      "eth_sendRawTransaction" ->
        [hextx] = params
        bintx = Base16.decode(hextx)
        tx = Chain.Transaction.from_rlp(bintx)

        # Testing transaction
        {res, code, err} =
          Chain.with_peak(fn peak ->
            state = Block.state(peak)
            apply_transaction(tx, peak, state)
          end)

        # Adding transacton, even when :nonce_too_high
        if err == nil or err["code"] == -32001 do
          Chain.Pool.add_transaction(tx, true)

          if Diode.dev_mode?() do
            Chain.Worker.work()
          end

          res = Base16.encode(Chain.Transaction.hash(tx))
          result(res, 200)
        else
          {res, code, err}
        end

      "parity_pendingTransactions" ->
        # todo
        result([])

      "eth_syncing" ->
        result(Diode.syncing?())

      "eth_chainId" ->
        id =
          Diode.chain_id()
          |> :binary.encode_unsigned()
          |> Base.encode16(case: :lower)
          |> String.trim_leading("0")

        result("0x" <> id)

      "eth_getTransactionByHash" ->
        [txh] = params
        txh = Base16.decode(txh)
        tx = ChainSql.transaction(txh)

        if tx == nil do
          throw(:notfound)
        end

        case tx do
          %Transaction{} ->
            block = ChainSql.block_by_txhash(txh)
            result(transaction_result(tx, block))

          nil ->
            result(nil, 404)
        end

      # Network.Rpc.handle_jsonrpc(%{"id" => 0, "method" => "eth_getBlockByNumber", "params" => ["0x0", false]})
      "eth_getBlockByHash" ->
        [ref, full] = params

        with_block_by_ref(ref, fn block -> get_block_rpc(block, full) end)
        |> result()

      "eth_getBlockByNumber" ->
        [ref, full] = params

        with_block(ref, fn block -> get_block_rpc(block, full) end)
        |> result()

      "eth_mining" ->
        mining =
          case Chain.Worker.mode() do
            :disabled -> false
            _ -> true
          end

        result(mining)

      "eth_hashrate" ->
        result(Stats.get(:hashrate, 0))

      "eth_accounts" ->
        addresses =
          Diode.wallets()
          |> Enum.map(&Wallet.address!/1)

        result(addresses)

      "eth_coinbase" ->
        result(Wallet.address!(Diode.miner()))

      "eth_getTransactionCount" ->
        get_account(params)
        |> Chain.Account.nonce()
        |> result()

      "eth_getBalance" ->
        get_account(params)
        |> Chain.Account.balance()
        |> result()

      "eth_getCode" ->
        get_account(params)
        |> Chain.Account.code()
        |> result()

      "eth_getCodeHash" ->
        get_account(params)
        |> Chain.Account.codehash()
        |> result()

      "eth_getStorageAt" ->
        [address, location, ref] = params

        get_account([address, ref])
        |> Chain.Account.storage_value(Base16.decode_int(location))
        |> result()

      "eth_getStorage" ->
        get_account(params)
        |> Chain.Account.tree()
        |> MerkleTree.to_list()
        |> result()

      "eth_estimateGas" ->
        # TODO real estimate
        result(Chain.gas_limit())

      "eth_call" ->
        [%{} = opts, ref] = params

        opts =
          Map.put_new(opts, "gas", Base16.encode(Chain.gas_limit(), false))
          |> Map.put_new("gasPrice", "0x0")
          |> decode_opts()

        data = opts["data"]

        wallet =
          case Map.get(opts, "from") do
            nil -> Wallet.new()
            from -> Wallet.from_address(from)
          end

        tx = create_transaction(wallet, data, opts, false)

        with_block(ref, fn block ->
          state = Block.state(block)
          apply_transaction(tx, block, state)
        end)

      "eth_getTransactionReceipt" ->
        # TODO
        [txh] = params
        txbin = Base16.decode(txh)

        case ChainSql.block_by_txhash(txbin) do
          nil ->
            result(nil, 404)

          block ->
            tx = ChainSql.transaction(txbin)

            logs =
              Block.logs(block)
              |> Enum.filter(fn log -> log["transactionHash"] == txbin end)

            [v, r, s] = Secp256k1.bitcoin_to_rlp(Transaction.signature(tx))

            ret = %{
              "transactionHash" => txh,
              "transactionIndex" => Block.transaction_index(block, tx),
              "blockHash" => Block.hash(block),
              "blockNumber" => Block.number(block),
              "from" => Transaction.from(tx),
              "to" => Transaction.to(tx),
              "gasUsed" => Block.transaction_gas(block, tx),
              "cumulativeGasUsed" => Block.gas_used(block),
              "contractAddress" => Transaction.new_contract_address(tx),
              "logs" => logs,
              "status" => Block.transaction_status(block, tx),
              "logsBloom" => Block.logs_bloom(block),
              "v" => v,
              "r" => r,
              "s" => s

              # Blockscout does not handle extra keys
              # "out" => Block.transaction_out(block, tx)
            }

            result(ret)
        end

      "eth_getLogs" ->
        [%{"fromBlock" => blockRef}] = params

        try do
          with_block(blockRef, &Block.logs/1)
          |> result()
        catch
          :notfound -> result([])
        end

      # eth_getLogs [#{<<"fromBlock">> => <<"0x7">>}]
      # curl -X POST --data '{"jsonrpc":"2.0","method":"eth_getLogs","params":["0x16"],"id":73}'
      # {
      #   "id":1,
      #   "jsonrpc":"2.0",
      #   "result": [{
      #     "logIndex": "0x1", // 1
      #     "blockNumber":"0x1b4", // 436
      #     "blockHash": "0x8216c5785ac562ff41e2dcfdf5785ac562ff41e2dcfdf829c5a142f1fccd7d",
      #     "transactionHash":  "0xdf829c5a142f1fccd7d8216c5785ac562ff41e2dcfdf5785ac562ff41e2dcf",
      #     "transactionIndex": "0x0", // 0
      #     "address": "0x16c5785ac562ff41e2dcfdf829c5a142f1fccd7d",
      #     "data":"0x0000000000000000000000000000000000000000000000000000000000000000",
      #     "topics": ["0x59ebeb90bc63057b6515673c3ecf9438e5058bca0f92585014eced636878c9a5"]
      #     },{
      #       ...
      #     }]
      # }

      "eth_blockNumber" ->
        result(Chain.peak())

      "eth_gasPrice" ->
        result(Chain.gas_price())

      "net_listening" ->
        result(true)

      "net_version" ->
        result(Integer.to_string(Diode.chain_id()))

      # curl --data '{"method":"trace_replayBlockTransactions","params":["0x2ed119",["trace"]],"id":1,"jsonrpc":"2.0"}' -H "Content-Type: application/json" -X POST localhost:8545
      "trace_replayBlockTransactions" ->
        [ref, ["trace"]] = params

        {txs, traces, number} =
          with_block(ref, fn block ->
            traces =
              Block.simulate(block)
              |> Block.receipts()

            {Block.transactions(block), traces, Block.number(block)}
          end)

        # reward =

        Enum.zip(txs, traces)
        |> Enum.map(fn {tx, rcpt} ->
          %{
            "output" => rcpt.evmout,
            "stateDiff" => nil,
            "trace" => [
              %{
                "action" => %{
                  "callType" => Atom.to_string(Transaction.type(tx)),
                  "from" => Transaction.from(tx),
                  "gas" => Transaction.gas_limit(tx),
                  "init" => Transaction.payload(tx),
                  "to" => Transaction.to(tx),
                  "value" => Transaction.value(tx)
                },
                "result" => %{
                  "gasUsed" => rcpt.gas_used,
                  "output" => rcpt.evmout
                },
                "subtraces" => {:raw, 0},
                "traceAddress" => [],
                "transactionHash" => Transaction.hash(tx),
                "transactionPosition" => {:raw, Enum.find_index(txs, &(&1 == tx))},
                "blockNumber" => {:raw, number},
                "type" =>
                  if Transaction.contract_creation?(tx) do
                    "create"
                  else
                    "call"
                  end
              }
            ],
            "vmTrace" => nil
          }
        end)
        |> result()

      # {
      #   "id": 1,
      #   "jsonrpc": "2.0",
      #   "result": [
      #     {
      #       "output": "0x",
      #       "stateDiff": null,
      #       "trace": [{
      #         "action": { ... },
      #         "result": {
      #           "gasUsed": "0x0",
      #           "output": "0x"
      #         },
      #         "subtraces": 0,
      #         "traceAddress": [],
      #         "type": "call"
      #       }],
      #       "vmTrace": null
      #     },
      #     { ... }
      #   ]
      # }

      "trace_block" ->
        [ref] = params

        {author, hash, number} =
          with_block(ref, fn block ->
            {Wallet.address!(Block.miner(block)), Block.hash(block), Block.number(block)}
          end)

        result([
          %{
            "action" => %{
              "author" => author,
              "rewardType" => "block",
              "value" => 0
            },
            "blockHash" => hash,
            "blockNumber" => {:raw, number},
            "subtraces" => {:raw, 0},
            "traceAddress" => [],
            "type" => "reward"
          }
        ])

      _ ->
        nil
    end
  end

  def execute_dio(method, params) do
    case method do
      "dio_getObject" ->
        key = Base16.decode(hd(params))

        case Kademlia.find_value(key) do
          nil -> result(nil, 404)
          binary -> result(Object.encode_list!(Object.decode!(binary)))
        end

      "dio_getNode" ->
        node = Base16.decode(hd(params))

        case Kademlia.find_node(node) do
          nil -> result(nil, 404)
          item -> result(Object.encode_list!(KBuckets.object(item)))
        end

      "dio_getPool" ->
        Chain.Pool.transactions()
        |> Enum.map(&transaction_list/1)
        |> result()

      "dio_codeCount" ->
        codehash = Base16.decode(hd(params))

        Chain.with_peak_state(fn pstate ->
          Chain.State.accounts(pstate)
          |> Enum.filter(fn {_key, account} -> Chain.Account.codehash(account) == codehash end)
          |> Enum.count()
          |> result()
        end)

      "dio_codeGroups" ->
        Chain.with_peak_state(fn pstate ->
          Chain.State.accounts(pstate)
          |> Enum.map(fn {_key, account} -> Chain.Account.codehash(account) end)
          |> Enum.reduce(%{}, fn hash, map ->
            Map.update(map, hash, 1, fn x -> x + 1 end)
          end)
          |> Json.prepare!(big_x: false)
          |> result()
        end)

      "dio_supply" ->
        Chain.with_peak_state(fn pstate ->
          Chain.State.accounts(pstate)
          |> Enum.map(fn {_key, account} -> Chain.Account.balance(account) end)
          |> Enum.sum()
          |> result()
        end)

      "dio_network" ->
        conns = Network.Server.get_connections(Network.PeerHandler)

        Kademlia.network()
        |> KBuckets.to_list()
        |> Enum.filter(fn item -> not KBuckets.is_self(item) end)
        |> Enum.map(fn item ->
          address = Wallet.address!(item.node_id)

          %{
            connected: Map.has_key?(conns, Wallet.address!(item.node_id)),
            last_seen: item.last_connected,
            last_error: item.last_error,
            node_id: address,
            node: KBuckets.object(item),
            retries: item.retries
          }
        end)
        |> result()

      "dio_accounts" ->
        Chain.with_peak_state(fn pstate ->
          State.accounts(pstate)
          |> Enum.map(fn {id, acc} ->
            {id,
             %{
               "codehash" => Account.codehash(acc),
               "balance" => Account.balance(acc),
               "nonce" => Account.nonce(acc)
             }}
          end)
          |> Map.new()
          |> result()
        end)

      "dio_edgev2" ->
        msg = hd(params) |> Base16.decode() |> Rlp.decode!()

        Network.EdgeV2.handle_rpc(msg)
        |> Rlp.encode!()
        |> Base16.encode()
        |> result()

      _ ->
        nil
    end
  end

  def execute_private(method, params) do
    case method do
      "eth_sendTransaction" ->
        [%{} = opts] = params

        opts = decode_opts(opts)
        %{"from" => from} = opts
        data = Map.get(opts, "data", "")
        wallet = Enum.find(Diode.wallets(), fn w -> Wallet.address!(w) == from end)
        tx = create_transaction(wallet, data, opts)

        Chain.Pool.add_transaction(tx, true)

        if Diode.dev_mode?() do
          Chain.Worker.work()
        end

        result(Chain.Transaction.hash(tx))

      _ ->
        nil
    end
  end

  def execute_dev(method, params) do
    case method do
      "evm_snapshot" ->
        case params do
          [] ->
            snapshot = Chain.state()
            file = :erlang.phash2(snapshot) |> Base16.encode(false)
            path = Diode.data_dir(file)
            Chain.store_file(path, snapshot)
            result(file)

          [file] ->
            if Enum.member?(File.ls!(Diode.data_dir()), file) do
              Chain.load_file(Diode.data_dir(file))
              |> Chain.set_state()

              result("")
            else
              result("", 404)
            end
        end

      "evm_revert" ->
        case params do
          [file] ->
            if Enum.member?(File.ls!(Diode.data_dir()), file) do
              Chain.load_file(Diode.data_dir(file))
              |> Chain.set_state()

              result("")
            else
              result("", 404)
            end
        end

      "evm_mine" ->
        Chain.Worker.work()
        result("", 200)

      _ ->
        nil
    end
  end

  defp get_account([address, ref]) do
    address = Base16.decode(address)

    with_block(ref, fn block ->
      block
      |> Block.state()
      |> Chain.State.ensure_account(address)
    end)
  end

  def with_block(nil, _fun), do: throw(:badrequest)
  def with_block(%Chain.Block{} = block, fun), do: fun.(block)
  def with_block(%Chain.BlockCache{} = block, fun), do: fun.(block)

  def with_block(ref, fun) do
    BlockProcess.with_block(ref, fn
      nil -> throw(:notfound)
      block -> fun.(block)
    end)
  end

  def with_block_by_ref(nil, _fun) do
    throw(:badrequest)
  end

  def with_block_by_ref(ref, fun) do
    BlockProcess.with_block(ref, fun)
  end

  def get_block_rpc(block, full) do
    miner = Block.miner(block)
    txs = Block.transactions(block)

    txs =
      if full == true do
        Enum.map(txs, fn tx -> transaction_result(tx, block) end)
      else
        Enum.map(txs, &Chain.Transaction.hash/1)
      end

    parentHash =
      case Block.parent_hash(block) do
        nil -> <<0::256>>
        bin -> bin
      end

    uncles = []
    uncleSha = Hash.keccak_256(Rlp.encode!(uncles))

    %{
      "number" => Block.number(block),
      "hash" => Block.hash(block),
      "parentHash" => parentHash,
      "nonce" => Block.nonce(block),
      "sha3Uncles" => uncleSha,
      "logsBloom" => Block.logs_bloom(block),
      "transactionsRoot" => Block.txhash(block),
      "stateRoot" => Block.state_hash(block),
      "miner" => Wallet.address!(miner),

      # Blockscout does not handle extra keys
      # "minerSignature" => block.header.miner_signature,

      "receiptsRoot" => Block.receipts_root(block),
      "difficulty" => Block.difficulty(block),
      "totalDifficulty" => Block.total_difficulty(block),
      "extraData" => Block.extra_data(block),
      "size" => Block.size(block),
      "gasLimit" => Block.gas_limit(block),
      "gasUsed" => Block.gas_used(block),
      "timestamp" => Block.timestamp(block),
      "transactions" => txs,
      "uncles" => uncles
    }
  end

  def decode_opts(opts) do
    Enum.map(opts, fn {key, value} ->
      value =
        case {key, value} do
          {_key, nil} -> nil
          {"to", _value} -> Base16.decode(value)
          {"from", _value} -> Base16.decode(value)
          {"data", _value} -> Base16.decode(value)
          {_key, _value} -> Base16.decode_int(value)
        end

      {key, value}
    end)
    |> Map.new()
  end

  def create_transaction(wallet, data, opts \\ %{}, sign \\ true) do
    from = Wallet.address!(wallet)

    gas = Map.get(opts, "gas", 0x15F90)
    gas_price = Map.get(opts, "gasPrice", 0x3B9ACA00)
    value = Map.get(opts, "value", 0x0)
    blockRef = Map.get(opts, "blockRef", "latest")

    chain_id =
      Map.get_lazy(opts, "chainId", fn ->
        with_block(blockRef, fn block -> Diode.chain_id(Block.number(block)) end)
      end)

    nonce =
      Map.get_lazy(opts, "nonce", fn ->
        with_block(blockRef, fn block ->
          Chain.Block.state(block)
          |> Chain.State.ensure_account(from)
          |> Chain.Account.nonce()
        end)
      end)

    tx =
      case Map.get(opts, "to") do
        nil ->
          # Contract creation
          %Chain.Transaction{
            to: nil,
            nonce: nonce,
            gasPrice: gas_price,
            gasLimit: gas,
            init: data,
            value: value,
            chain_id: chain_id
          }

        to ->
          # Normal transaction
          %Chain.Transaction{
            to: to,
            nonce: nonce,
            gasPrice: gas_price,
            gasLimit: gas,
            data: data,
            value: value,
            chain_id: chain_id
          }
      end

    if sign do
      Chain.Transaction.sign(tx, Wallet.privkey!(wallet))
    else
      %{tx | signature: {:fake, Wallet.address!(wallet)}}
    end
  end

  defp result(result, code \\ 200, error \\ nil) do
    {result, code, error}
  end

  defp transaction_list(%Transaction{} = tx) do
    [v, r, s] = Secp256k1.bitcoin_to_rlp(Transaction.signature(tx))

    %{
      "from" => Transaction.from(tx),
      "gasPrice" => Transaction.gas_price(tx),
      "hash" => Transaction.hash(tx),
      "input" => Transaction.payload(tx),
      "nonce" => Transaction.nonce(tx),
      "to" => Transaction.to(tx),
      "value" => Transaction.value(tx),
      "v" => v,
      "r" => r,
      "s" => s
    }
  end

  defp transaction_result(%Transaction{} = tx, %Chain.Block{} = block) do
    [v, r, s] = Secp256k1.bitcoin_to_rlp(Transaction.signature(tx))

    %{
      "blockHash" => Block.hash(block),
      "blockNumber" => Block.number(block),
      "from" => Transaction.from(tx),
      "gas" => Transaction.gas_limit(tx),
      "gasPrice" => Transaction.gas_price(tx),
      "hash" => Transaction.hash(tx),
      "input" => Transaction.payload(tx),
      "nonce" => Transaction.nonce(tx),
      "to" => Transaction.to(tx),
      "transactionIndex" => Block.transaction_index(block, tx),
      "value" => Transaction.value(tx),
      "v" => v,
      "r" => r,
      "s" => s
    }
  end

  defp apply_transaction(tx, block, state) do
    case Chain.Transaction.apply(tx, block, state) do
      {:ok, _state, rcpt = %{msg: :ok}} ->
        result(rcpt.evmout, 200)

      {:ok, _state, rcpt} ->
        {error, reason} =
          case rcpt.msg do
            :evmc_revert ->
              {:evmc_revert, text} = ABI.decode_revert(rcpt.evmout)
              {"revert", text}

            _other ->
              {rcpt.msg, rcpt.msg}
          end

        result(%{
          "error" => %{
            "message" => "VM Exception while processing transaction: #{error} #{reason}",
            "code" => -32000,
            "data" => %{
              Transaction.hash(tx) => %{
                "error" => "#{error}",
                "return" => rcpt.evmout,
                # "program_counter" => 123,
                "reason" => "#{reason}"
              }
              # "name" => "o",
              # "stack" => "o: ..."
            }
          }
        })

      {:error, :nonce_too_high} ->
        result(nil, 400, %{
          "message" => "Transaction failed, nonce too high",
          "code" => -32001
        })

      {:error, reason} ->
        result(nil, 400, %{
          "message" => "Transaction failed: #{inspect(reason)}",
          "code" => -33000
        })
    end
  end
end

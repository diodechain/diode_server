# Diode Server
# Copyright 2019 IoT Blockchain Technology Corporation LLC (IBTC)
# Licensed under the Diode License, Version 1.0
defmodule Network.Rpc do
  alias Chain.BlockCache, as: Block
  alias Chain.Transaction

  def handle_jsonrpc(rpcs, opts \\ [])

  def handle_jsonrpc(%{"_json" => rpcs}, opts) when is_list(rpcs) do
    handle_jsonrpc(rpcs, opts)
  end

  def handle_jsonrpc(rpcs, opts) when is_list(rpcs) do
    body =
      Enum.reduce(rpcs, [], fn rpc, acc ->
        {_status, body} = handle_jsonrpc(rpc, opts)
        [body | acc]
        # :io.format("~p~n", [body])
      end)
      |> Enum.reverse()

    {200, body}
  end

  def handle_jsonrpc(body_params, opts) when is_map(body_params) do
    # :io.format("handle_jsonrpc: ~p~n", [body_params])

    %{
      "method" => method,
      "id" => id
    } = body_params

    params = Map.get(body_params, "params", [])

    {result, code, error} =
      try do
        execute_rpc(method, params, opts)
      catch
        :notfound -> {nil, 404, %{"message" => "Not found"}}
      end

    envelope = %{
      "id" => id,
      "jsonrpc" => "2.0",
      "result" => Json.prepare!(result, false)
    }

    if error == nil do
      # :io.format("handle_jsonrpc = ~p~n", [envelope])
      {code, envelope}
    else
      envelope = Map.put(envelope, "error", Json.prepare!(error, false))
      # :io.format("handle_jsonrpc: = ~p~n", [envelope])
      {code, envelope}
    end
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
    {422, "what method?"}
  end

  def execute_rpc(method, params, opts) do
    apis = [
      {true, {__MODULE__, :execute_std}},
      {Diode.dev_mode?(), {__MODULE__, :execute_dev}},
      {opts[:private], {__MODULE__, :execute_private}},
      {opts[:extra], opts[:extra]}
    ]

    execute(apis, [method, params])
  end

  def execute_std(method, params) do
    case method do
      "net_peerCount" ->
        peers = Network.Server.get_connections(Network.PeerHandler)
        result(map_size(peers))

      "net_edgeCount" ->
        peers = Network.Server.get_connections(Network.EdgeHandler)
        result(map_size(peers))

      "eth_sendRawTransaction" ->
        [hextx] = params
        bintx = Base16.decode(hextx)
        tx = Chain.Transaction.from_rlp(bintx)

        # Testing transaction
        peak = Chain.peakBlock()
        state = Block.state(peak)

        err =
          case Chain.Transaction.apply(tx, peak, state) do
            {:ok, _state, %{msg: :ok}} ->
              nil

            {:ok, _state, rcpt} ->
              %{
                "messsage" => "VM Exception while processing transaction: #{rcpt.msg}",
                "code" => if(rcpt.msg == :evmc_revert, do: -32000, else: -31000),
                "data" => rcpt.evmout
              }

            # Adding a too high nonce still to the pool
            {:error, :nonce_too_high} ->
              nil

            {:error, reason} ->
              %{
                "messsage" => "Transaction error #{reason}"
              }
          end

        # Adding transaciton
        if err == nil do
          Chain.Pool.add_transaction(tx)
        end

        if Diode.dev_mode?() do
          Chain.Worker.work()
        end

        res = Base16.encode(Chain.Transaction.hash(tx))
        result(res, 200, err)

      "parity_pendingTransactions" ->
        # todo
        result([])

      "eth_syncing" ->
        result(Diode.syncing?())

      "eth_chainId" ->
        result(Diode.chain_id())

      "eth_getTransactionByHash" ->
        [txh] = params
        txh = Base16.decode(txh)
        tx = Store.transaction(txh)

        case tx do
          %Transaction{} ->
            block = Chain.block_by_hash(Store.transaction_block(txh))
            result(transaction_result(tx, block))

          nil ->
            result(nil, 404, "Not found")
        end

      # Network.Rpc.handle_jsonrpc(%{"id" => 0, "method" => "eth_getBlockByNumber", "params" => ["0x0", false]})
      "eth_getBlockByNumber" ->
        [ref, full] = params
        block = get_block(ref)

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

        ret = %{
          "number" => Block.number(block),
          "hash" => Block.hash(block),
          "parentHash" => parentHash,
          "nonce" => Block.nonce(block),
          "sha3Uncles" => uncleSha,
          "logsBloom" => Block.logsBloom(block),
          "transactionsRoot" => Block.txhash(block),
          "stateRoot" => Block.state_hash(block),
          "miner" => Wallet.address!(miner),

          # Blockscout does not handle extra keys
          # "minerSignature" => block.header.miner_signature,

          "receiptsRoot" => Block.receiptsRoot(block),
          "difficulty" => Block.difficulty(block),
          "totalDifficulty" => Block.totalDifficulty(block),
          "extraData" => Block.extraData(block),
          "size" => Block.size(block),
          "gasLimit" => Block.gasLimit(block),
          "gasUsed" => Block.gasUsed(block),
          "timestamp" => Block.timestamp(block),
          "transactions" => txs,
          "uncles" => uncles
        }

        result(ret)

      "eth_mining" ->
        mining =
          case Chain.Worker.mode() do
            :disabled -> false
            _ -> true
          end

        result(mining)

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

      "eth_estimateGas" ->
        # TODO real estimate
        result(Chain.gasLimit())

      "eth_call" ->
        [%{} = opts, ref] = params

        opts = decode_opts(opts)
        data = opts["data"]

        wallet =
          case Map.get(opts, "from") do
            nil ->
              Wallet.new()

            from ->
              Enum.find(Diode.wallets(), Wallet.new(), fn w -> Wallet.address!(w) == from end)
          end

        tx = create_transaction(wallet, data, opts)

        block = get_block(ref)
        state = Block.state(block)
        {:ok, _state, rcpt} = Chain.Transaction.apply(tx, block, state)

        res = rcpt.evmout

        err =
          if rcpt.msg == :ok do
            nil
          else
            %{
              "messsage" => "VM Exception while processing transaction: #{rcpt.msg}",
              "code" => if(rcpt.msg == :evmc_revert, do: -32000, else: -31000),
              "data" => rcpt.evmout
            }
          end

        result(res, 200, err)

      "eth_getTransactionReceipt" ->
        # TODO
        [txh] = params
        txbin = Base16.decode(txh)

        case Store.transaction_block(txbin) do
          nil ->
            result(nil)

          hash ->
            block = Chain.block_by_hash(hash)
            tx = Store.transaction(txbin)

            logs =
              Block.logs(block)
              |> Enum.filter(fn log -> log["transactionHash"] == txbin end)

            [v, r, s] = Secp256k1.bitcoin_to_rlp(Transaction.signature(tx))

            ret = %{
              "transactionHash" => txh,
              "transactionIndex" => Block.transactionIndex(block, tx),
              "blockHash" => Block.hash(block),
              "blockNumber" => Block.number(block),
              "from" => Transaction.from(tx),
              "to" => Transaction.to(tx),
              "gasUsed" => Block.transactionGas(block, tx),
              "cumulativeGasUsed" => Block.gasUsed(block),
              "contractAddress" => Transaction.new_contract_address(tx),
              "logs" => logs,
              "status" => Block.transactionStatus(block, tx),
              "logsBloom" => Block.logsBloom(block),
              "v" => v,
              "r" => r,
              "s" => s

              # Blockscout does not handle extra keys
              # "out" => Block.transactionOut(block, tx)
            }

            result(ret)
        end

      "eth_getLogs" ->
        [%{"fromBlock" => blockRef}] = params

        try do
          block = get_block(blockRef)
          result(Block.logs(block))
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
        block = get_block(ref)
        txs = Block.transactions(block)

        # reward =

        traces =
          Block.simulate(block, false)
          |> Block.receipts()

        traces =
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
                  "transactionPosition" => {:raw, Block.transactionIndex(block, tx)},
                  "blockNumber" => {:raw, Block.number(block)},
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
        result(traces)

      "trace_block" ->
        [ref] = params
        block = get_block(ref)

        ret = [
          %{
            "action" => %{
              "author" => Wallet.address!(Block.miner(block)),
              "rewardType" => "block",
              "value" => 0
            },
            "blockHash" => Block.hash(block),
            "blockNumber" => {:raw, Block.number(block)},
            "subtraces" => {:raw, 0},
            "traceAddress" => [],
            "type" => "reward"
          }
        ]

        result(ret)

      _ ->
        nil
    end
  end

  def execute_private(method, params) do
    case method do
      "eth_sendTransaction" ->
        [%{} = opts] = params

        opts = decode_opts(opts)
        %{"from" => from, "data" => data} = opts
        wallet = Enum.find(Diode.wallets(), fn w -> Wallet.address!(w) == from end)
        tx = create_transaction(wallet, data, opts)

        Chain.Pool.add_transaction(tx)

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
            path = Diode.dataDir(file)
            Chain.store_file(path, snapshot)
            result(file)

          [file] ->
            if Enum.member?(File.ls!(Diode.dataDir()), file) do
              Chain.load_file(Diode.dataDir(file))
              |> Chain.set_state()

              result("")
            else
              result("", 404)
            end
        end

      "evm_revert" ->
        case params do
          [file] ->
            if Enum.member?(File.ls!(Diode.dataDir()), file) do
              Chain.load_file(Diode.dataDir(file))
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

    get_block(ref)
    |> Block.state()
    |> Chain.State.ensure_account(address)
  end

  def get_block(ref) do
    case ref do
      %Chain.Block{} ->
        ref

      %Chain.BlockCache{} ->
        ref

      "latest" ->
        Chain.peakBlock()

      "pending" ->
        Chain.Worker.candidate()

      "earliest" ->
        Chain.block(0)

      <<"0x", _rest::binary()>> ->
        get_block(Base16.decode_int(ref))

      num when is_integer(num) ->
        case Chain.block(num) do
          %Chain.Block{} = block -> block
          nil -> throw(:notfound)
        end
    end
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

  def create_transaction(wallet, data, opts \\ %{}) do
    from = Wallet.address!(wallet)

    gas = Map.get(opts, "gas", 0x15F90)
    gas_price = Map.get(opts, "gasPrice", 0x3B9ACA00)
    value = Map.get(opts, "value", 0x0)
    blockRef = Map.get(opts, "blockRef", "latest")

    nonce =
      Map.get_lazy(opts, "nonce", fn ->
        Chain.Block.state(get_block(blockRef))
        |> Chain.State.ensure_account(from)
        |> Chain.Account.nonce()
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
            value: value
          }

        to ->
          # Normal transaction
          %Chain.Transaction{
            to: to,
            nonce: nonce,
            gasPrice: gas_price,
            gasLimit: gas,
            data: data,
            value: value
          }
      end
      |> Chain.Transaction.sign(Wallet.privkey!(wallet))

    tx
  end

  defp result(result, code \\ 200, error \\ nil) do
    {result, code, error}
  end

  defp transaction_result(%Transaction{} = tx, %Chain.Block{} = block) do
    [v, r, s] = Secp256k1.bitcoin_to_rlp(Transaction.signature(tx))

    %{
      "blockHash" => Block.hash(block),
      "blockNumber" => Block.number(block),
      "from" => Transaction.from(tx),
      "gas" => Block.transactionGas(block, tx),
      "gasPrice" => Transaction.gas_price(tx),
      "hash" => Transaction.hash(tx),
      "input" => Transaction.payload(tx),
      "nonce" => Transaction.nonce(tx),
      "to" => Transaction.to(tx),
      "transactionIndex" => Block.transactionIndex(block, tx),
      "value" => Transaction.value(tx),
      "v" => v,
      "r" => r,
      "s" => s
    }
  end
end

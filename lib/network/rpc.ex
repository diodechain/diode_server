defmodule Network.Rpc do
  alias Chain.BlockCache, as: Block
  alias Chain.Transaction

  def handle_jsonrpc(%{"_json" => rpcs}) when is_list(rpcs) do
    body =
      Enum.reduce(rpcs, [], fn rpc, acc ->
        {_status, body} = handle_jsonrpc(rpc)
        [body | acc]
        # :io.format("~p~n", [body])
      end)
      |> Enum.reverse()

    {200, body}
  end

  def handle_jsonrpc(body_params) when is_map(body_params) do
    %{
      "method" => method,
      "params" => params,
      "id" => id
    } = body_params

    ret =
      try do
        handle_jsonrpc(id, method, params)
      catch
        :notfound -> result(id, nil, 404, %{"message" => "Not found"})
      end

    # :io.format("handle_jsonrpc(~p) =>~n~p~n", [body_params, ret])
    ret
  end

  defp handle_jsonrpc(id, method, params) do
    if Diode.dev_mode?() do
      IO.puts("#{method}")
    end

    case method do
      "eth_sendRawTransaction" ->
        [hextx] = params
        bintx = Base16.decode(hextx)
        tx = Chain.Transaction.from_rlp(bintx)

        # Testing transaction
        peak = Chain.peakBlock()
        state = Block.state(peak)
        {:ok, rcpt} = Chain.Transaction.apply(tx, peak, state)

        # :io.format("Receipt: ~p~n", [rcpt])

        Chain.Pool.add_transaction(tx)

        res = Base16.encode(Chain.Transaction.hash(tx))

        err =
          if rcpt.msg == :ok do
            nil
          else
            %{
              "messsage" => "VM Exception while processing transaction: #{rcpt.msg}",
              "code" => if(rcpt.msg == :revert, do: -32000, else: -31000),
              "data" => rcpt.evmout
            }
          end

        result(id, res, 200, err)

      "parity_pendingTransactions" ->
        # todo
        result(id, [])

      "eth_getTransactionByHash" ->
        [txh] = params
        txh = Base16.decode(txh)
        tx = Store.transaction(txh)
        block = Chain.block_by_hash(Store.transaction_block(txh))

        result(id, transaction_result(tx, block))

      "eth_getTransactionCount" ->
        [address, ref] = params
        address = Base16.decode(address)
        block = getBlock(ref)
        state = Block.state(block)

        nonce =
          case Chain.State.account(state, address) do
            %Chain.Account{nonce: nonce} -> nonce
            nil -> 0
          end

        result(id, nonce)

      # Network.Rpc.handle_jsonrpc(%{"id" => 0, "method" => "eth_getBlockByNumber", "params" => ["0x0", false]})
      "eth_getBlockByNumber" ->
        [ref, full] = params
        block = getBlock(ref)

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

        result(id, ret)

      "eth_accounts" ->
        addresses =
          Diode.wallets()
          |> Enum.map(&Wallet.address!/1)

        result(id, addresses)

      "eth_getBalance" ->
        [address, ref] = params
        address = Base16.decode(address)

        %Chain.Block{} = block = getBlock(ref)
        state = Block.state(block)

        balance =
          case Chain.State.account(state, address) do
            %Chain.Account{balance: balance} -> balance
            nil -> 0
          end

        result(id, balance)

      "eth_getCode" ->
        [address, ref] = params
        address = Base16.decode(address)

        %Chain.Block{} = block = getBlock(ref)
        state = Block.state(block)

        code =
          case Chain.State.account(state, address) do
            %Chain.Account{code: code} -> code
            nil -> ""
          end

        result(id, code)

      "eth_estimateGas" ->
        # TODO real estimate
        result(id, Chain.gasLimit())

      "eth_sendTransaction" ->
        [%{} = opts] = params

        opts = decode_opts(opts)
        %{"from" => from, "data" => data} = opts
        wallet = Enum.find(Diode.wallets(), fn w -> Wallet.address!(w) == from end)
        tx = create_transaction(wallet, data, opts)

        Chain.Pool.add_transaction(tx)
        result(id, Chain.Transaction.hash(tx))

      "eth_call" ->
        [%{} = opts, ref] = params

        opts = decode_opts(opts)
        %{"from" => from, "data" => data} = opts
        wallet = Enum.find(Diode.wallets(), fn w -> Wallet.address!(w) == from end)
        tx = create_transaction(wallet, data, opts)

        block = getBlock(ref)
        state = Block.state(block)
        {:ok, rcpt} = Chain.Transaction.apply(tx, block, state)

        res = rcpt.evmout

        err =
          if rcpt.msg == :ok do
            nil
          else
            %{
              "messsage" => "VM Exception while processing transaction: #{rcpt.msg}",
              "code" => if(rcpt.msg == :revert, do: -32000, else: -31000),
              "data" => rcpt.evmout
            }
          end

        result(id, res, 200, err)

      "eth_getTransactionReceipt" ->
        # TODO
        [txh] = params
        txbin = Base16.decode(txh)

        case Store.transaction_block(txbin) do
          nil ->
            result(id, nil)

          hash ->
            block = Chain.block_by_hash(hash)
            tx = Store.transaction(txbin)

            ret = %{
              "transactionHash" => txh,
              "transactionIndex" => Block.transactionIndex(block, tx),
              "blockNumber" => Block.number(block),
              "blockHash" => Block.hash(block),
              "cumulativeGasUsed" => Block.gasUsed(block),
              "gasUsed" => Block.transactionGas(block, tx),
              "contractAddress" => Transaction.new_contract_address(tx),
              "logs" => [],
              "logsBloom" => Block.logsBloom(block),
              "status" => Block.transactionStatus(block, tx)

              # Blockscout does not handle extra keys
              # "out" => Block.transactionOut(block, tx)
            }

            result(id, ret)
        end

      "eth_blockNumber" ->
        result(id, Chain.peak())

      "net_listening" ->
        result(id, true)

      "net_version" ->
        result(id, "41043")

      # TODO
      "eth_subscribe" ->
        result(id, "0x12345")

      # TODO
      "eth_unsubscribe" ->
        result(id, true)

      # curl --data '{"method":"trace_replayBlockTransactions","params":["0x2ed119",["trace"]],"id":1,"jsonrpc":"2.0"}' -H "Content-Type: application/json" -X POST localhost:8545
      "trace_replayBlockTransactions" ->
        [ref, ["trace"]] = params
        block = getBlock(ref)
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
                  "action" =>
                    if Transaction.contract_creation?(tx) do
                      %{
                        "callType" => "create",
                        "from" => Transaction.from(tx),
                        "gas" => Transaction.gasLimit(tx),
                        "init" => Transaction.payload(tx),
                        "to" => Transaction.to(tx),
                        "value" => Transaction.value(tx)
                      }
                    else
                      %{
                        "callType" => "call",
                        "from" => Transaction.from(tx),
                        "gas" => Transaction.gasLimit(tx),
                        "input" => Transaction.payload(tx),
                        "to" => Transaction.to(tx),
                        "value" => Transaction.value(tx)
                      }
                    end,
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
        result(id, traces)

      "trace_block" ->
        [ref] = params
        block = getBlock(ref)

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

        result(id, ret)

      _ ->
        if Diode.dev_mode?() do
          handle_dev(id, method, params)
        else
          :io.format("Unhandled: ~p ~p~n", [method, params])
          {422, "what method?"}
        end
    end
  end

  def handle_dev(id, method, params) do
    case method do
      "evm_mine" ->
        Chain.Worker.work()
        result(id, 200, "")

      _ ->
        :io.format("Unhandled: ~p ~p~n", [method, params])
        {422, "what method?"}
    end
  end

  def getBlock(ref) do
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
        getBlock(Base16.decode_int(ref))

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
    gasPrice = Map.get(opts, "gasPrice", 0x3B9ACA00)
    value = Map.get(opts, "value", 0x0)
    blockRef = Map.get(opts, "blockRef", "latest")

    nonce =
      Map.get_lazy(opts, "nonce", fn ->
        Chain.Block.state(getBlock(blockRef))
        |> Chain.State.ensure_account(from)
        |> Chain.Account.nonce()
      end)

    tx =
      case Map.get(opts, "to") do
        nil ->
          # Contraction creation
          %Chain.Transaction{
            to: nil,
            nonce: nonce,
            gasPrice: gasPrice,
            gasLimit: gas,
            init: data,
            value: value
          }

        to ->
          # Normal transaction
          %Chain.Transaction{
            to: to,
            nonce: nonce,
            gasPrice: gasPrice,
            gasLimit: gas,
            data: data,
            value: value
          }
      end
      |> Chain.Transaction.sign(Wallet.privkey!(wallet))

    tx
  end

  defp result(id, result, code \\ 200, error \\ nil) do
    if error == nil do
      {code,
       %{
         "id" => id,
         "jsonrpc" => "2.0",
         "result" => Json.prepare!(result, false)
       }}
    else
      {code,
       %{
         "id" => id,
         "jsonrpc" => "2.0",
         "result" => Json.prepare!(result, false),
         "error" => Json.prepare!(error, false)
       }}
    end
  end

  defp transaction_result(%Transaction{} = tx, %Chain.Block{} = block) do
    [v, r, s] = Secp256k1.bitcoin_to_rlp(Transaction.signature(tx))

    %{
      "blockHash" => Block.hash(block),
      "blockNumber" => Block.number(block),
      "from" => Transaction.from(tx),
      "gas" => Block.transactionGas(block, tx),
      "gasPrice" => Transaction.gasPrice(tx),
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

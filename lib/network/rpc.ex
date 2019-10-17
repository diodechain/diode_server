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
      "id" => id
    } = body_params

    params = Map.get(body_params, "params", [])

    ret =
      try do
        handle_jsonrpc(id, method, params)
      catch
        :notfound -> result(id, nil, 404, %{"message" => "Not found"})
      end

    if Diode.dev_mode?() do
      if method == "__eth_gettransaction_receipt" do
        :io.format("~s ~0p =>~n~0p~n", [method, params, ret])
      else
        :io.format("~s~n", [method])
      end
    end

    ret
  end

  defp handle_jsonrpc(id, method, params) do
    case method do
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
                "code" => if(rcpt.msg == :revert, do: -32000, else: -31000),
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
        block = get_block(ref)
        state = Block.state(block)

        nonce =
          case Chain.State.account(state, address) do
            %Chain.Account{nonce: nonce} -> nonce
            nil -> 0
          end

        result(id, nonce)

      # Network.Rpc.handle_jsonrpc(%{"id" => 0, "method" => "eth_get_blockByNumber", "params" => ["0x0", false]})
      "eth_get_blockByNumber" ->
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

        parent_hash =
          case Block.parent_hash(block) do
            nil -> <<0::256>>
            bin -> bin
          end

        uncles = []
        uncle_sha = Hash.keccak_256(Rlp.encode!(uncles))

        ret = %{
          "number" => Block.number(block),
          "hash" => Block.hash(block),
          "parent_hash" => parent_hash,
          "nonce" => Block.nonce(block),
          "sha3Uncles" => uncle_sha,
          "logs_bloom" => Block.logs_bloom(block),
          "transactionsRoot" => Block.txhash(block),
          "stateRoot" => Block.state_hash(block),
          "miner" => Wallet.address!(miner),

          # Blockscout does not handle extra keys
          # "minerSignature" => block.header.miner_signature,

          "receipts_root" => Block.receipts_root(block),
          "difficulty" => Block.difficulty(block),
          "total_difficulty" => Block.total_difficulty(block),
          "extra_data" => Block.extra_data(block),
          "size" => Block.size(block),
          "gas_limit" => Block.gas_limit(block),
          "gas_used" => Block.gas_used(block),
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

        %Chain.Block{} = block = get_block(ref)
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

        %Chain.Block{} = block = get_block(ref)
        state = Block.state(block)

        code =
          case Chain.State.account(state, address) do
            %Chain.Account{code: code} -> code
            nil -> ""
          end

        result(id, code)

      "eth_estimateGas" ->
        # TODO real estimate
        result(id, Chain.gas_limit())

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

        result(id, Chain.Transaction.hash(tx))

      "eth_call" ->
        [%{} = opts, ref] = params

        opts = decode_opts(opts)
        %{"from" => from, "data" => data} = opts
        wallet = Enum.find(Diode.wallets(), fn w -> Wallet.address!(w) == from end)
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
              "code" => if(rcpt.msg == :revert, do: -32000, else: -31000),
              "data" => rcpt.evmout
            }
          end

        result(id, res, 200, err)

      "eth_gettransaction_receipt" ->
        # TODO
        [txh] = params
        txbin = Base16.decode(txh)

        case Store.transaction_block(txbin) do
          nil ->
            result(id, nil)

          hash ->
            block = Chain.block_by_hash(hash)
            tx = Store.transaction(txbin)

            logs =
              Block.logs(block)
              |> Enum.filter(fn log -> log["transactionHash"] == txbin end)

            [v, r, s] = Secp256k1.bitcoin_to_rlp(Transaction.signature(tx))

            ret = %{
              "transactionHash" => txh,
              "transaction_index" => Block.transaction_index(block, tx),
              "blockHash" => Block.hash(block),
              "blockNumber" => Block.number(block),
              "from" => Transaction.from(tx),
              "to" => Transaction.to(tx),
              "gas_used" => Block.transaction_gas(block, tx),
              "cumulativegas_used" => Block.gas_used(block),
              "contractAddress" => Transaction.new_contract_address(tx),
              "logs" => logs,
              "status" => Block.transaction_status(block, tx),
              "logs_bloom" => Block.logs_bloom(block),
              "v" => v,
              "r" => r,
              "s" => s

              # Blockscout does not handle extra keys
              # "out" => Block.transaction_out(block, tx)
            }

            result(id, ret)
        end

      "eth_getLogs" ->
        [%{"fromBlock" => block_ref}] = params

        try do
          block = get_block(block_ref)
          result(id, Block.logs(block))
        catch
          :notfound -> result(id, [])
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
      #     "transaction_index": "0x0", // 0
      #     "address": "0x16c5785ac562ff41e2dcfdf829c5a142f1fccd7d",
      #     "data":"0x0000000000000000000000000000000000000000000000000000000000000000",
      #     "topics": ["0x59ebeb90bc63057b6515673c3ecf9438e5058bca0f92585014eced636878c9a5"]
      #     },{
      #       ...
      #     }]
      # }

      "eth_blockNumber" ->
        result(id, Chain.peak())

      "eth_gas_price" ->
        result(id, Chain.gas_price())

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
                    "gas_used" => rcpt.gas_used,
                    "output" => rcpt.evmout
                  },
                  "subtraces" => {:raw, 0},
                  "traceAddress" => [],
                  "transactionHash" => Transaction.hash(tx),
                  "transactionPosition" => {:raw, Block.transaction_index(block, tx)},
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
        #           "gas_used": "0x0",
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
      "evm_snapshot" ->
        case params do
          [] ->
            snapshot = Chain.state()
            file = :erlang.phash2(snapshot) |> Base16.encode(false)
            path = Diode.data_dir(file)
            Chain.store_file(path, snapshot)
            result(id, file)

          [file] ->
            if Enum.member?(File.ls!(Diode.data_dir()), file) do
              Chain.load_file(Diode.data_dir(file))
              |> Chain.set_state()

              result(id, "")
            else
              result(id, "", 404)
            end
        end

      "evm_revert" ->
        case params do
          [file] ->
            if Enum.member?(File.ls!(Diode.data_dir()), file) do
              Chain.load_file(Diode.data_dir(file))
              |> Chain.set_state()

              result(id, "")
            else
              result(id, "", 404)
            end
        end

      "evm_mine" ->
        Chain.Worker.work()
        result(id, "", 200)

      _ ->
        :io.format("Unhandled: ~p ~p~n", [method, params])
        {422, "what method?"}
    end
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
    gas_price = Map.get(opts, "gas_price", 0x3B9ACA00)
    value = Map.get(opts, "value", 0x0)
    block_ref = Map.get(opts, "block_ref", "latest")

    nonce =
      Map.get_lazy(opts, "nonce", fn ->
        Chain.Block.state(get_block(block_ref))
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
            gas_price: gas_price,
            gas_limit: gas,
            init: data,
            value: value
          }

        to ->
          # Normal transaction
          %Chain.Transaction{
            to: to,
            nonce: nonce,
            gas_price: gas_price,
            gas_limit: gas,
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
      "gas" => Block.transaction_gas(block, tx),
      "gas_price" => Transaction.gas_price(tx),
      "hash" => Transaction.hash(tx),
      "input" => Transaction.payload(tx),
      "nonce" => Transaction.nonce(tx),
      "to" => Transaction.to(tx),
      "transaction_index" => Block.transaction_index(block, tx),
      "value" => Transaction.value(tx),
      "v" => v,
      "r" => r,
      "s" => s
    }
  end
end

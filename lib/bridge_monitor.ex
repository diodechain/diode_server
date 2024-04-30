# Diode Server
# Copyright 2021-2024 Diode
# Licensed under the Diode License, Version 1.1
defmodule BridgeMonitor do
  use GenServer
  require Logger
  defstruct trusted: false, last_block: nil

  @validators MapSet.new(
                [
                  "0x937c492a77ae90de971986d003ffbc5f8bb2232c",
                  "0xae699211c62156b8f29ce17be47d2f069a27f2a6",
                  "0xceca2f8cf1983b4cf0c1ba51fd382c2bc37aba58",
                  "0x7e4cd38d266902444dc9c8f7c0aa716a32497d0b",
                  "0x68e0bafdda9ef323f692fc080d612718c941d120",
                  "0x1350d3b501d6842ed881b59de4b95b27372bfae8"
                ]
                |> Enum.map(&Base16.decode/1)
              )

  @bridge_out_native Hash.to_address(0x2C303A315A1EE4C377E28121BAF30146E229731B)

  @bridges %{
    1284 => Hash.to_address(0xA32A9ED71FBF22E6D197C13725AD61958E9A4499)
  }

  def start_link(_args) do
    GenServer.start_link(
      __MODULE__,
      %BridgeMonitor{trusted: MapSet.member?(@validators, Wallet.address!(Diode.miner()))},
      name: __MODULE__
    )
  end

  def init(state = %{trusted: trusted}) do
    if trusted do
      Logger.info("Starting BridgeMonitor, this node is a trusted validator")
      PubSub.subscribe(:rpc)
    end

    {:ok, state}
  end

  def handle_info(
        {:rpc, :block, _block_hash},
        state = %BridgeMonitor{last_block: last, trusted: true}
      ) do
    hash = Chain.with_final(fn block -> Chain.Block.hash(block) end)

    if last != hash do
      check_bridge(hash)
    end

    {:noreply, %BridgeMonitor{state | last_block: hash}}
  end

  def handle_info({:rpc, _other, _msg}, state) do
    {:noreply, state}
  end

  def check_bridge(hash) do
    from_chain_id = Diode.chain_id()

    for {chain_id, bridge} <- @bridges do
      {len, _gas} = local_call(hash, "txsLength", ["uint256"], [chain_id])
      len = :binary.decode_unsigned(len)

      in_len =
        ABI.encode_call("inTxsLength", ["uint256"], [from_chain_id])
        |> remote_call(chain_id, bridge)
        |> Base16.decode_int()

      if len > in_len do
        # Transaction:
        # address sender;
        # address destination;
        # uint256 amount;
        # uint256 timestamp;
        # uint256 blockNumber;
        # bytes32 historyHash;

        %{
          sender: sender,
          destination: destination,
          amount: amount,
          timestamp: timestamp,
          historyHash: historyHash
        } = get_tx(hash, chain_id, len - 1)

        sender = sender |> Base16.encode()
        destination = destination |> Base16.encode()
        amount = amount / Shell.ether(1)

        witness =
          ABI.encode_call("in_witnesses", ["bytes32", "address"], [
            historyHash,
            Wallet.address!(Diode.miner())
          ])
          |> remote_call(chain_id, bridge)
          |> Base16.decode_int()

        if witness == 0 do
          Logger.info(
            "Adding witness for Transaction[#{len}]: #{sender} -> #{destination} #{amount} at #{timestamp}"
          )

          sig =
            Secp256k1.sign(Wallet.privkey!(Diode.miner()), historyHash, :none)
            |> Secp256k1.bitcoin_to_rlp()

          ABI.encode_call("addInWitness", ["bytes32", "uint8", "bytes32", "bytes32"], [
            historyHash | sig
          ])
          |> exec_tx(chain_id, bridge)
        else
          score =
            ABI.encode_call("trustScore", ["bytes32"], [historyHash])
            |> remote_call(chain_id, bridge)
            |> Base16.decode_int()

          threshold =
            ABI.encode_call("in_threshold")
            |> remote_call(chain_id, bridge)
            |> Base16.decode_int()

          if score >= threshold do
            Logger.info(
              "Transaction[#{len}] is now confirmed: #{sender} -> #{destination} #{amount}"
            )

            txs =
              Enum.map(in_len..(len - 1), fn idx ->
                %{destination: destination, amount: amount} = get_tx(hash, chain_id, idx)
                [destination, amount]
              end)

            ABI.encode_call("bridgeIn", ["uint256", "(address,uint256)[]"], [from_chain_id, txs])
            |> exec_tx(chain_id, bridge)
          end
        end
      end
    end
  end

  defp get_tx(block_ref, chain_id, idx) do
    {tx, _gas} = local_call(block_ref, "txsAt", ["uint256", "uint256"], [chain_id, idx])

    [sender, destination, amount, timestamp, _blockNumber, historyHash] =
      ABI.decode_types(["address", "address", "uint256", "uint256", "uint256", "bytes32"], tx)

    %{
      sender: sender,
      destination: destination,
      amount: amount,
      timestamp: timestamp,
      historyHash: historyHash
    }
  end

  defp local_call(block_ref, method, types, arguments) do
    Shell.call(@bridge_out_native, method, types, arguments, blockRef: block_ref)
  end

  defp remote_call(abi, chain_id, bridge) do
    RemoteChain.RPC.call!(
      chain_id,
      Base16.encode(bridge, false),
      Base16.encode(Wallet.address!(Diode.miner())),
      Base16.encode(abi)
    )
  end

  defp exec_tx(abi, chain_id, bridge) do
    gas_price = RemoteChain.RPC.gas_price(chain_id) |> Base16.decode_int()
    nonce = RemoteChain.NonceProvider.nonce(chain_id)

    tx =
      Shell.raw(CallPermit.wallet(), abi,
        to: bridge,
        chainId: chain_id,
        gas: 12_000_000,
        gasPrice: gas_price + div(gas_price, 10),
        value: 0,
        nonce: nonce
      )

    payload = tx |> Chain.Transaction.to_rlp() |> Rlp.encode!() |> Base16.encode()

    tx_hash = Chain.Transaction.hash(tx) |> Base16.encode()

    Logger.info("Submitting BridgeTX: #{tx_hash} (#{inspect(tx)})")
    # We're pushing to the TxRelay keep alive server to ensure the TX
    # is broadcasted even if the RPC connection goes down in the next remote_call.
    # This is so to preserve the nonce ordering if at all possible
    RemoteChain.TxRelay.keep_alive(chain_id, tx, payload)

    # In order to ensure delivery we're broadcasting to all known endpoints of this chain_id
    spawn(fn ->
      RemoteChain.RPC.send_raw_transaction(chain_id, payload)

      for endpoint <- RemoteChain.chainimpl(chain_id).rpc_endpoints() do
        RemoteChain.HTTP.send_raw_transaction(endpoint, payload)
      end
    end)
  end
end

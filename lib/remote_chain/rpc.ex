# Diode Server
# Copyright 2021-2024 Diode
# Licensed under the Diode License, Version 1.1
defmodule RemoteChain.RPC do
  require Logger

  def get_proof(chain, address, keys, block \\ "latest") do
    # requires https://eips.ethereum.org/EIPS/eip-1186
    rpc!(chain, "eth_getProof", [address, keys, block])
  end

  def block_number(chain) do
    rpc!(chain, "eth_blockNumber")
  end

  def get_block_by_number(chain, block \\ "latest", with_transactions \\ false) do
    rpc!(chain, "eth_getBlockByNumber", [block, with_transactions])
  end

  def get_storage_at(chain, address, slot, block \\ "latest") do
    rpc!(chain, "eth_getStorageAt", [address, slot, block])
  end

  def get_code(chain, address, block \\ "latest") do
    rpc!(chain, "eth_getCode", [address, block])
  end

  def get_transaction_count(chain, address, block \\ "latest") do
    rpc!(chain, "eth_getTransactionCount", [address, block])
  end

  def get_transaction_by_hash(chain, hash) do
    rpc!(chain, "eth_getTransactionByHash", [hash])
  end

  def get_balance(chain, address, block \\ "latest") do
    rpc!(chain, "eth_getBalance", [address, block])
  end

  def gas_price(chain) do
    rpc!(chain, "eth_gasPrice", [])
  end

  def send_raw_transaction(chain, tx) do
    case rpc(chain, "eth_sendRawTransaction", [tx]) do
      {:ok, tx_hash} -> tx_hash
      {:error, %{"code" => -32603, "message" => "already known"}} -> :already_known
      {:error, error} -> {:error, error}
    end
  end

  def rpc!(chain, method, params \\ []) do
    case rpc(chain, method, params) do
      {:ok, result} -> result
      {:error, error} -> raise "RPC error: #{inspect(error)}"
    end
  end

  def rpc(chain, method, params) do
    case RemoteChain.NodeProxy.rpc(chain, method, params) do
      %{"result" => result} -> {:ok, result}
      %{"error" => error} -> {:error, error}
    end
  end

  def call(chain, to, from, data, block \\ "latest") do
    rpc(chain, "eth_call", [%{to: to, data: data, from: from}, block])
  end

  def call!(chain, to, from, data, block \\ "latest") do
    {:ok, ret} = call(chain, to, from, data, block)
    ret
  end

  def estimate_gas(chain, to, data, block \\ "latest") do
    rpc!(chain, "eth_estimateGas", [%{to: to, data: data}, block])
  end
end

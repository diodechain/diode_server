defmodule Moonbeam do
  # https://github.com/moonbeam-foundation/moonbeam/blob/master/precompiles/call-permit/CallPermit.sol
  @address Base16.decode("0x000000000000000000000000000000000000080A")
  @endpoint "https://moonbeam-alpha.api.onfinality.io/public"
  # @endpoint "https://rpc.api.moonbase.moonbeam.network"

  def epoch() do
    0
  end

  def peak() do
    1000
  end

  def genesis_hash() do
    # https://moonbase.moonscan.io/block/0
    0x33638DDE636F9264B6472B9D976D58E757FE88BADAC53F204F3F530ECC5AACFA
  end

  def light_node?() do
    true
  end

  def get_proof(address, keys, block \\ "latest") do
    # requires https://eips.ethereum.org/EIPS/eip-1186
    rpc!("eth_getProof", [address, keys, block])
  end

  def block_number() do
    rpc!("eth_blockNumber")
  end

  def get_block_by_number(block \\ "lastest", with_transactions \\ false) do
    rpc!("eth_getBlockByNumber", [block, with_transactions])
  end

  def get_storage_at(address, slot, block \\ "latest") do
    rpc!("eth_getStorageAt", [address, slot, block])
  end

  def get_transaction_count(address, block \\ "latest") do
    rpc!("eth_getTransactionCount", [address, block])
  end

  def get_balance(address, block \\ "latest") do
    rpc!("eth_getBalance", [address, block])
  end

  def rpc!(method, params \\ []) do
    request = %{
      jsonrpc: "2.0",
      method: method,
      params: params,
      id: 1
    }

    {:ok, %{body: body}} =
      HTTPoison.post(@endpoint, Jason.encode!(request), [{"Content-Type", "application/json"}])

    case Jason.decode!(body) do
      %{"result" => result} ->
        result

      %{"error" => error} ->
        raise "RPC error: #{inspect(error)}"
    end
  end

  def call!(data) do
    rpc!("eth_call", [
      %{
        to: Base16.encode(@address),
        data: Base16.encode(data)
      },
      "latest"
    ])
  end

  def chain_id() do
    # Moonbase Alpha (0x507)
    1287
  end
end

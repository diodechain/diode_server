defmodule CallPermit do
  def address() do
    Base16.decode("0x000000000000000000000000000000000000080A")
  end

  # 0xe7f13b866a7fc159cb6ee32bcb4103cf0477652e
  def wallet() do
    Diode.wallet()
  end

  # /// @dev Dispatch a call on the behalf of an other user with a EIP712 permit.
  # /// Will revert if the permit is not valid or if the dispatched call reverts or errors (such as
  # /// out of gas).
  # /// If successful the EIP712 nonce is increased to prevent this permit to be replayed.
  # /// @param from Who made the permit and want its call to be dispatched on their behalf.
  # /// @param to Which address the call is made to.
  # /// @param value Value being transfered from the "from" account.
  # /// @param data Call data
  # /// @param gaslimit Gaslimit the dispatched call requires.
  # ///     Providing it prevents the dispatcher to manipulate the gaslimit.
  # /// @param deadline Deadline in UNIX seconds after which the permit will no longer be valid.
  # /// @param v V part of the signature.
  # /// @param r R part of the signature.
  # /// @param s S part of the signature.
  # /// @return output Output of the call.
  # /// @custom:selector b5ea0966
  def dispatch(from, to, value, data, gaslimit, deadline, v, r, s) do
    ABI.encode_call(
      "dispatch",
      [
        "address",
        "address",
        "uint256",
        "bytes",
        "uint64",
        "uint256",
        "uint8",
        "bytes32",
        "bytes32"
      ],
      [from, to, value, data, gaslimit, deadline, v, r, s]
    )
  end

  def nonces(owner) do
    ABI.encode_call("nonces", ["address"], [owner])
  end

  def domain_separator() do
    ABI.encode_call("DOMAIN_SEPARATOR", [], [])
  end

  def rpc_call!(chain, call, from \\ nil, blockref \\ "latest") do
    {:ok, ret} = rpc_call(chain, call, from, blockref)
    ret
  end

  def rpc_call(chain, call, from \\ nil, blockref \\ "latest") do
    from = if from != nil, do: Base16.encode(from)
    RemoteChain.RPC.call(chain, Base16.encode(address()), from, Base16.encode(call), blockref)
  end
end

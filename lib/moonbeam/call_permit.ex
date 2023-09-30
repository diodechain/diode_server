defmodule CallPermit do
  @domain_separator Base16.decode(
                      "0x2d44830364594de15bf34f87ca86da8d1967e5bc7d64b301864028acb9120412"
                    )

  def address() do
    Base16.decode("0x000000000000000000000000000000000000080A")
  end

  # 0xe7f13b866a7fc159cb6ee32bcb4103cf0477652e
  def wallet() do
    {:wallet,
     <<205, 186, 242, 6, 129, 177, 86, 35, 141, 148, 105, 188, 131, 116, 84, 18, 226, 131, 244,
       208, 162, 155, 231, 186, 90, 212, 147, 79, 134, 68, 17, 170>>,
     <<2, 155, 102, 229, 244, 105, 136, 238, 53, 54, 160, 44, 171, 93, 3, 183, 210, 90, 143, 207,
       59, 161, 223, 135, 222, 113, 0, 8, 88, 55, 222, 249, 70>>,
     <<231, 241, 59, 134, 106, 127, 193, 89, 203, 110, 227, 43, 203, 65, 3, 207, 4, 119, 101, 46>>}
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

  def call_permit(from_wallet, to, value, data, gaslimit, deadline) do
    from = Wallet.address!(from_wallet)
    nonce = rpc_call!(nonces(from)) |> Base16.decode_int()

    signature =
      EIP712.encode(@domain_separator, "CallPermit", [
        {"from", "address", from},
        {"to", "address", to},
        {"value", "uint256", value},
        {"data", "bytes", data},
        {"gaslimit", "uint64", gaslimit},
        {"nonce", "uint256", nonce},
        {"deadline", "uint256", deadline}
      ])

    [v, r, s] =
      Wallet.sign!(from_wallet, signature, :none)
      |> Secp256k1.bitcoin_to_rlp()

    dispatch(from, to, value, data, gaslimit, deadline, v, r, s)
  end

  # Making a BNS register call
  def test() do
    bns = Base16.decode("0x75140F88B0F4B2FBC6DADC16CC51203ADB07FE36")

    other_wallet =
      {:wallet,
       <<168, 72, 60, 32, 26, 244, 241, 69, 33, 155, 57, 121, 27, 21, 88, 28, 204, 144, 133, 121,
         249, 232, 26, 246, 75, 105, 137, 103, 59, 96, 250, 145>>,
       <<2, 234, 139, 191, 188, 193, 51, 129, 233, 219, 195, 29, 184, 143, 180, 241, 241, 125,
         151, 17, 194, 147, 145, 66, 214, 210, 149, 111, 30, 152, 115, 246, 28>>,
       <<111, 57, 182, 104, 128, 82, 13, 111, 164, 185, 235, 166, 127, 6, 48, 118, 214, 19, 2, 6>>}

    gas_limit = 500_000
    deadline = 1_800_000_000

    call =
      ABI.encode_call("Register", ["string", "address"], [
        "anotheraccount",
        Wallet.address!(other_wallet)
      ])

    call_permit(other_wallet, bns, 0, call, gas_limit, deadline)
    |> rpc_call!()
  end

  def test2() do
    bns = Base16.decode("0x75140F88B0F4B2FBC6DADC16CC51203ADB07FE36")

    other_wallet =
      {:wallet,
       <<168, 72, 60, 32, 26, 244, 241, 69, 33, 155, 57, 121, 27, 21, 88, 28, 204, 144, 133, 121,
         249, 232, 26, 246, 75, 105, 137, 103, 59, 96, 250, 145>>,
       <<2, 234, 139, 191, 188, 193, 51, 129, 233, 219, 195, 29, 184, 143, 180, 241, 241, 125,
         151, 17, 194, 147, 145, 66, 214, 210, 149, 111, 30, 152, 115, 246, 28>>,
       <<111, 57, 182, 104, 128, 82, 13, 111, 164, 185, 235, 166, 127, 6, 48, 118, 214, 19, 2, 6>>}

    gas_limit = 500_000
    deadline = 1_800_000_000

    call = ABI.encode_call("Version")

    call_permit(other_wallet, bns, 0, call, gas_limit, deadline)
    |> rpc_call!()
  end

  def rpc_call!(call, from \\ nil, blockref \\ "latest") do
    {:ok, ret} = rpc_call(call, from, blockref)
    ret
  end

  def rpc_call(call, from \\ nil, blockref \\ "latest") do
    from = if from != nil, do: Base16.encode(from)
    Moonbeam.call(Base16.encode(address()), from, Base16.encode(call), blockref)
  end

  # CallPermit.call!(CallPermit.domain_separator())
end

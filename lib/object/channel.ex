# Diode Server
# Copyright 2019 IoT Blockchain Technology Corporation LLC (IBTC)
# Licensed under the Diode License, Version 1.0
defmodule Object.Channel do
  require Record
  @behaviour Object

  Record.defrecord(:channel,
    server_id: nil,
    block_number: nil,
    fleet_contract: nil,
    type: nil,
    name: nil,
    params: [],
    signature: nil
  )

  @type channel ::
          record(:channel,
            server_id: binary(),
            block_number: integer(),
            fleet_contract: binary(),
            type: binary(),
            name: binary(),
            params: [],
            signature: Secp256k1.signature()
          )

  def new(server_id, fleet, name, device_sig) do
    channel(server_id: server_id, fleet_contract: fleet, name: name, signature: device_sig)
  end

  @spec key(channel()) :: Object.key()
  def key(channel(fleet_contract: fleet, type: type, name: name, params: params)) do
    params = Rlp.encode!(params) |> Hash.keccak_256()
    Diode.hash(<<fleet::binary-size(20), type::binary, name::binary, params::binary>>)
  end

  def valid?(ch = channel()) do
    valid_type?(ch) and valid_device?(ch) and valid_params?(ch)
  end

  def valid_device?(ch = channel(fleet_contract: fleet)) do
    Contract.Fleet.device_allowlisted?(fleet, device_address(ch))
  end

  def valid_params?(channel(params: [])), do: true
  def valid_params?(_), do: false

  def valid_type?(channel(type: "mailbox")), do: true
  def valid_type?(channel(type: "broadcast")), do: true
  def valid_type?(_), do: false

  def device_address(rec = channel(signature: signature)) do
    Secp256k1.recover!(signature, message(rec), :kec)
    |> Wallet.from_pubkey()
    |> Wallet.address!()
  end

  defp message(
         channel(
           block_number: num,
           server_id: id,
           fleet_contract: fleet,
           type: type,
           name: name,
           params: params
         )
       ) do
    params = Rlp.encode!(params) |> Diode.hash()

    ["channel", id, Chain.Block.hash(Chain.block(num)), fleet, type, name, params]
    |> Enum.map(&ABI.encode("bytes32", &1))
    |> :erlang.iolist_to_binary()
  end

  def sign(ch = channel(), private) do
    channel(ch, signature: Secp256k1.sign(private, message(ch), :kec))
  end

  def block_number(channel(block_number: block_number)), do: block_number
  def server_id(channel(server_id: server_id)), do: server_id
  def fleet_contract(channel(fleet_contract: fleet_contract)), do: fleet_contract
  def type(channel(type: type)), do: type
  def name(channel(name: name)), do: name
  def params(channel(params: params)), do: params
  def signature(channel(signature: signature)), do: signature
end

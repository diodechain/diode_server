# Diode Server
# Copyright 2021-2024 Diode
# Licensed under the Diode License, Version 1.1
defmodule Object.Data do
  require Record
  @behaviour Object

  Record.defrecord(:data,
    block_number: nil,
    name: nil,
    value: nil,
    signature: nil
  )

  @type data ::
          record(:data,
            block_number: integer(),
            name: binary(),
            value: binary(),
            signature: Secp256k1.signature()
          )

  def new(block_num, name, value, private) do
    sign(data(block_number: block_num, name: name, value: value), private)
  end

  @impl true
  @spec key(data()) :: Object.key()
  def key(d = data(name: name)) do
    key(owner_address(d), name)
  end

  def key(addr = <<_::160>>, name) do
    Diode.hash(<<"data", addr::binary-size(20), name::binary>>)
  end

  @impl true
  def valid?(_data) do
    true
  end

  def owner_address(rec = data(signature: signature)) do
    Secp256k1.recover!(signature, message(rec), :kec)
    |> Wallet.from_pubkey()
    |> Wallet.address!()
  end

  defp message(data(block_number: num, name: name, value: value)) do
    ["data", num, Chain.blockhash(num), name, value]
    |> Enum.map(&ABI.encode("bytes32", &1))
    |> :erlang.iolist_to_binary()
  end

  def sign(d = data(), private) do
    data(d, signature: Secp256k1.sign(private, message(d), :kec))
  end

  def value(data(value: value)), do: value
  def name(data(name: name)), do: name
  @impl true
  def block_number(data(block_number: block_number)), do: block_number
  def signature(data(signature: signature)), do: signature
end

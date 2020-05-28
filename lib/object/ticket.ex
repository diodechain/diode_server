# Diode Server
# Copyright 2019 IoT Blockchain Technology Corporation LLC (IBTC)
# Licensed under the Diode License, Version 1.0
defmodule Object.Ticket do
  alias Chain.BlockCache, as: Block
  require Record
  @behaviour Object

  Record.defrecord(:ticket,
    server_id: nil,
    block_number: nil,
    fleet_contract: nil,
    total_connections: nil,
    total_bytes: nil,
    local_address: nil,
    device_signature: nil,
    server_signature: nil
  )

  @type ticket ::
          record(:ticket,
            server_id: binary(),
            block_number: integer(),
            fleet_contract: binary(),
            total_connections: integer(),
            total_bytes: integer(),
            local_address: binary(),
            device_signature: Secp256k1.signature(),
            server_signature: Secp256k1.signature() | nil
          )

  def key(tck = ticket()) do
    device_address(tck)
  end

  def device_address(tck = ticket()) do
    Secp256k1.recover!(
      device_signature(tck),
      device_blob(tck),
      :kec
    )
    |> Wallet.from_pubkey()
    |> Wallet.address!()
  end

  def device_sign(tck = ticket(), private) do
    ticket(tck, device_signature: Secp256k1.sign(private, device_blob(tck), :kec))
  end

  def server_sign(tck = ticket(), private) do
    ticket(tck, server_signature: Secp256k1.sign(private, server_blob(tck), :kec))
  end

  @doc """
    Format for putting into a transaction with "SubmitTicketRaw"
  """
  def raw(tck = ticket()) do
    [rec, r, s] = Secp256k1.bitcoin_to_rlp(device_signature(tck))

    [
      block_number(tck),
      fleet_contract(tck),
      server_id(tck),
      total_connections(tck),
      total_bytes(tck),
      Hash.sha3_256(local_address(tck)),
      r,
      s,
      rec
    ]
  end

  def device_blob(tck = ticket()) do
    # From DiodeRegistry.sol:
    #   bytes32[] memory message = new bytes32[](6);
    #   message[0] = blockhash(blockHeight);
    #   message[1] = bytes32(fleetContract);
    #   message[2] = bytes32(nodeAddress);
    #   message[3] = bytes32(totalConnections);
    #   message[4] = bytes32(totalBytes);
    #   message[5] = localAddress;
    [
      block_hash(tck),
      fleet_contract(tck),
      server_id(tck),
      total_connections(tck),
      total_bytes(tck),
      Hash.sha3_256(local_address(tck))
    ]
    |> Enum.map(&ABI.encode("bytes32", &1))
    |> :erlang.iolist_to_binary()
  end

  def server_blob(tck = ticket()) do
    [device_blob(tck), device_signature(tck)]
    |> :erlang.iolist_to_binary()
  end

  def epoch(ticket), do: block(ticket) |> Block.epoch()

  def server_id(ticket(server_id: id)), do: id
  def block_number(ticket(block_number: block)), do: block
  def block(ticket(block_number: block)), do: Chain.block(block)
  def block_hash(ticket), do: block(ticket) |> Block.hash()
  def device_signature(ticket(device_signature: signature)), do: signature
  def server_signature(ticket(server_signature: signature)), do: signature
  def fleet_contract(ticket(fleet_contract: fc)), do: fc
  def total_connections(ticket(total_connections: tc)), do: tc
  def total_bytes(ticket(total_bytes: tb)), do: tb
  def local_address(ticket(local_address: la)), do: la
end

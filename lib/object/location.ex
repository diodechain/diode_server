defmodule Object.Ticket do
  @moduledoc """
  ConnectionTicket, should rename?
  """
  require Record
  @behaviour Object

  Record.defrecord(:ticket,
    server_id: nil,
    peak_block: nil,
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
            peak_block: binary(),
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
      device_blob(tck)
    )
    |> Wallet.from_pubkey()
    |> Wallet.address!()
  end

  # def ticket_id(tck = ticket()) do
  #   {device_address(tck), fleet_contract(tck),
  # end

  def device_sign(tck = ticket(), private) do
    ticket(tck, device_signature: Secp256k1.sign(private, device_blob(tck)))
  end

  @spec device_verify(ticket(), binary() | Wallet.t()) :: boolean()
  def device_verify(tck = ticket(), id) do
    Secp256k1.verify(id, device_blob(tck), device_signature(tck))
  end

  def server_sign(tck = ticket(), private) do
    ticket(tck, server_signature: Secp256k1.sign(private, server_blob(tck)))
  end

  def device_blob(tck = ticket()) do
    BertExt.encode!([
      server_id(tck),
      peak_block(tck),
      fleet_contract(tck),
      total_connections(tck),
      total_bytes(tck),
      local_address(tck)
    ])
  end

  def server_blob(tck = ticket()) do
    BertExt.encode!([
      server_id(tck),
      peak_block(tck),
      fleet_contract(tck),
      total_connections(tck),
      total_bytes(tck),
      local_address(tck),
      device_signature(tck)
    ])
  end

  def server_id(ticket(server_id: id)), do: id
  def peak_block(ticket(peak_block: block)), do: block
  def device_signature(ticket(device_signature: signature)), do: signature
  def server_signature(ticket(server_signature: signature)), do: signature
  def fleet_contract(ticket(fleet_contract: fc)), do: fc
  def total_connections(ticket(total_connections: tc)), do: tc
  def total_bytes(ticket(total_bytes: tb)), do: tb
  def local_address(ticket(local_address: la)), do: la
end

defmodule Object.Location do
  require Record
  @behaviour Object

  Record.defrecord(:location,
    server_id: nil,
    peak_block: nil,
    device_signature: nil,
    server_signature: nil
  )

  @type location ::
          record(:location,
            server_id: binary(),
            peak_block: integer(),
            device_signature: Secp256k1.signature(),
            server_signature: Secp256k1.signature()
          )

  def key(loc = location()) do
    Secp256k1.recover!(
      device_signature(loc),
      device_blob(loc)
    )
    |> Wallet.from_pubkey()
    |> Wallet.address!()
  end

  def device_sign(loc = location(), private) do
    location(loc, device_signature: Secp256k1.sign(private, device_blob(loc)))
  end

  @spec device_verify(location(), binary() | Id.t()) :: boolean()
  def device_verify(loc = location(), id) do
    Secp256k1.verify(id, device_blob(loc), device_signature(loc))
  end

  def server_sign(loc = location(), private) do
    location(loc, server_signature: Secp256k1.sign(private, server_blob(loc)))
  end

  def device_blob(loc = location()) do
    BertExt.encode!([
      server_id(loc),
      peak_block(loc)
    ])
  end

  @spec server_blob({:location, any(), any(), any(), any()}) :: binary()
  def server_blob(loc = location()) do
    BertExt.encode!([
      server_id(loc),
      peak_block(loc),
      device_signature(loc)
    ])
  end

  def server_id(location(server_id: id)) do
    id
  end

  def peak_block(location(peak_block: block)) do
    block
  end

  def device_signature(location(device_signature: signature)) do
    signature
  end

  def server_signature(location(server_signature: signature)) do
    signature
  end
end

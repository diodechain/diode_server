# Diode Server
# Copyright 2019 IoT Blockchain Technology Corporation LLC (IBTC)
# Licensed under the Diode License, Version 1.0
defmodule RegistryTest do
  alias Object.Ticket
  import Ticket
  alias Contract.Registry
  use ExUnit.Case, async: false
  import Edge2Client

  setup_all do
    Chain.reset_state()

    if Chain.peak() < 2 do
      Chain.Worker.work()
      Chain.Worker.work()
    end

    Chain.sync()
    :ok
  end

  test "future ticket" do
    tck =
      ticket(
        server_id: Wallet.address!(Diode.miner()),
        total_connections: 1,
        total_bytes: 0,
        local_address: "spam",
        block_number: Chain.peak() + 10,
        fleet_contract: <<0::unsigned-size(160)>>,
        device_signature: Secp256k1.sign(clientkey(1), Hash.sha3_256("random"))
      )

    raw = Ticket.raw(tck)
    tx = Registry.submitTicketRawTx(raw)
    ret = Shell.call_tx(tx, "latest")
    {{:evmc_revert, "Ticket from the future?"}, _} = ret
    # if you get a  {{:evmc_revert, ""}, 85703} here it means for some reason the transaction
    # passed the initial test but failed on fleet_contract == 0
  end

  test "zero ticket" do
    tck =
      ticket(
        server_id: Wallet.address!(Diode.miner()),
        total_connections: 1,
        total_bytes: 0,
        local_address: "spam",
        block_number: Chain.peak() - 2,
        fleet_contract: <<0::unsigned-size(160)>>
      )
      |> Ticket.device_sign(clientkey(1))

    raw = Ticket.raw(tck)
    tx = Registry.submitTicketRawTx(raw)
    {{:evmc_revert, ""}, _} = Shell.call_tx(tx, "latest")
  end

  test "unregistered device" do
    tck =
      ticket(
        server_id: Wallet.address!(Diode.miner()),
        total_connections: 1,
        total_bytes: 0,
        local_address: "spam",
        block_number: Chain.peak() - 2,
        fleet_contract: Diode.fleet_address()
      )
      |> Ticket.device_sign(clientkey(1))

    raw = Ticket.raw(tck)
    tx = Registry.submitTicketRawTx(raw)
    {{:evmc_revert, "Unregistered device"}, _} = Shell.call_tx(tx, "latest")
  end

  test "registered device" do
    # Registering the device:
    tx = Contract.Fleet.set_device_whitelist(clientid(1), true)
    Chain.Pool.add_transaction(tx)
    Chain.Worker.work()

    assert Contract.Fleet.device_whitelisted?(clientid(1)) == true

    tck =
      ticket(
        server_id: Wallet.address!(Diode.miner()),
        total_connections: 1,
        total_bytes: 0,
        local_address: "spam",
        block_number: Chain.peak() - 2,
        fleet_contract: Diode.fleet_address()
      )
      |> Ticket.device_sign(clientkey(1))

    raw = Ticket.raw(tck)
    tx = Registry.submitTicketRawTx(raw)
    {"", _gas_cost} = Shell.call_tx(tx, "latest")
  end
end

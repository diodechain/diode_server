# Diode Server
# Copyright 2021 Diode
# Licensed under the Diode License, Version 1.1
defmodule RegistryTest do
  alias Object.Ticket
  import Ticket
  alias Contract.{Fleet, Registry}
  use ExUnit.Case, async: false
  import Edge2Client
  import While

  setup_all do
    Chain.reset_state()

    while Chain.peak() < Chain.epoch_length() do
      Chain.Worker.work()
    end

    :ok
  end

  test "future ticket" do
    tck =
      ticket(
        server_id: Wallet.address!(Diode.miner()),
        total_connections: 1,
        total_bytes: 0,
        local_address: "spam",
        block_number: Chain.peak() + Chain.epoch_length(),
        fleet_contract: <<0::unsigned-size(160)>>,
        device_signature: Secp256k1.sign(clientkey(1), Hash.sha3_256("random"))
      )

    raw = Ticket.raw(tck)
    tx = Registry.submit_ticket_raw_tx(raw)
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
        block_number: Chain.peak() - Chain.epoch_length(),
        fleet_contract: <<0::unsigned-size(160)>>
      )
      |> Ticket.device_sign(clientkey(1))

    raw = Ticket.raw(tck)
    tx = Registry.submit_ticket_raw_tx(raw)
    {{:evmc_revert, ""}, _} = Shell.call_tx(tx, "latest")
  end

  test "unregistered device" do
    # Ensuring queue is empty
    Chain.Worker.work()

    # Creating new tx
    op = ac = Wallet.address!(Diode.miner())
    fleet_tx = Fleet.deploy_new(op, ac)
    Chain.Pool.add_transaction(fleet_tx)
    Chain.Worker.work()

    fleet = Chain.Transaction.new_contract_address(fleet_tx)
    IO.puts("fleet: #{Base16.encode(fleet)}")

    client = clientid(1)
    assert Fleet.operator(fleet) == op
    assert Fleet.accountant(fleet) == ac
    assert Fleet.device_allowlisted?(fleet, client) == false

    tck =
      ticket(
        server_id: Wallet.address!(Diode.miner()),
        total_connections: 1,
        total_bytes: 0,
        local_address: "spam",
        block_number: Chain.peak() - Chain.epoch_length(),
        fleet_contract: fleet
      )
      |> Ticket.device_sign(clientkey(1))

    raw = Ticket.raw(tck)
    tx = Registry.submit_ticket_raw_tx(raw)

    error = "Unregistered device (#{Base16.encode(Wallet.address!(client))})"
    {{:evmc_revert, ^error}, _} = Shell.call_tx(tx, "latest")

    # Now registering device
    tx = Fleet.set_device_allowlist(fleet, client, true)
    Chain.Pool.add_transaction(tx)
    Chain.Worker.work()

    assert Fleet.device_allowlisted?(fleet, client) == true

    tck =
      ticket(
        server_id: Wallet.address!(Diode.miner()),
        total_connections: 1,
        total_bytes: 0,
        local_address: "spam",
        block_number: Chain.peak() - Chain.epoch_length(),
        fleet_contract: fleet
      )
      |> Ticket.device_sign(clientkey(1))

    raw = Ticket.raw(tck)
    tx = Registry.submit_ticket_raw_tx(raw)
    {"", _gas_cost} = Shell.call_tx(tx, "latest")
  end

  test "registered device (dev_contract)" do
    assert Fleet.device_allowlisted?(clientid(1)) == true

    tck =
      ticket(
        server_id: Wallet.address!(Diode.miner()),
        total_connections: 1,
        total_bytes: 0,
        local_address: "spam",
        block_number: Chain.peak() - Chain.epoch_length(),
        fleet_contract: Diode.fleet_address()
      )
      |> Ticket.device_sign(clientkey(1))

    raw = Ticket.raw(tck)
    tx = Registry.submit_ticket_raw_tx(raw)
    {"", _gas_cost} = Shell.call_tx(tx, "latest")
  end
end

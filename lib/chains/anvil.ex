# Diode Server
# Copyright 2021-2024 Diode
# Licensed under the Diode License, Version 1.1
defmodule Chains.Anvil do
  def chain_id(), do: 31337
  def expected_block_intervall(), do: 15
  def epoch(n), do: div(RemoteChain.blocktime(__MODULE__, n), epoch_length())

  def epoch_progress(n),
    do: rem(RemoteChain.blocktime(__MODULE__, n), epoch_length()) / epoch_length()

  def epoch_length(), do: 2_592_000
  def chain_prefix(), do: "av"

  def rpc_endpoints(),
    do: ["http://localhost:8545"]

  def ws_endpoints(),
    do: ["ws://localhost:8545"]

  def registry_address(),
    do:
      ensure_contract("DiodeRegistryLight", [
        foundation_address() |> Base16.encode(),
        diode_token_address() |> Base16.encode()
      ])

  def developer_fleet_address(),
    do:
      ensure_contract("DevFleetContract", [foundation_address() |> Base16.encode()], fn address ->
        Shell.transaction(
          Diode.wallet(),
          diode_token_address(),
          "mint",
          ["address", "uint256"],
          [
            Diode.address(),
            100_000_000_000_000_000
          ],
          chainId: chain_id()
        )

        # |> Shell.await_tx()

        Shell.transaction(
          Diode.wallet(),
          diode_token_address(),
          "approve",
          ["address", "uint256"],
          [registry_address(), 100_000_000_000_000_000],
          chainId: chain_id()
        )

        # |> Shell.await_tx()

        Shell.transaction(
          Diode.wallet(),
          registry_address(),
          "ContractStake",
          ["address", "uint256"],
          [address, 100_000_000_000_000_000],
          chainId: chain_id()
        )

        # |> Shell.await_tx()
      end)

  def bridge_address(), do: wallet_address()
  def foundation_address(), do: wallet_address()

  def diode_token_address(),
    do:
      ensure_contract("DiodeToken", [
        foundation_address() |> Base16.encode(),
        bridge_address() |> Base16.encode(),
        "true"
      ])

  def wallet_address() do
    System.get_env("WALLETS")
    |> String.split(" ")
    |> hd()
    |> Base16.decode()
    |> Wallet.from_privkey()
    |> Wallet.address!()
  end

  def ensure_contract(name, args, postfun \\ nil) do
    case :persistent_term.get({__MODULE__, name}, nil) do
      nil ->
        key = System.get_env("WALLETS") |> String.split(" ") |> hd()

        {text, 0} =
          System.cmd(
            "forge",
            [
              "create",
              "--rpc-url",
              "http://localhost:8545",
              "--private-key",
              key,
              "test/contract_src/#{name}.sol:#{name}",
              "--constructor-args" | args
            ],
            stderr_to_stdout: true
          )

        [_, address] = Regex.run(~r/Deployed to: (0x.{40})/, text)
        address = Base16.decode(address)
        :persistent_term.put({__MODULE__, name}, address)
        if postfun != nil, do: postfun.(address)
        address

      value ->
        value
    end
  end

  def transaction_hash(), do: &Hash.keccak_256/1
end

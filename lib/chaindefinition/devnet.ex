# Diode Server
# Copyright 2021-2024 Diode
# Licensed under the Diode License, Version 1.1
defmodule ChainDefinition.Devnet do
  alias Chain.Account, as: Account

  def network(_blockheight) do
    %ChainDefinition{
      block_reward_position: :last,
      chain_id: 5777,
      check_window: true,
      get_block_hash_limit: 131_072,
      min_diversity: 0,
      min_transaction_fee: true,
      allow_contract_override: false,
      double_spend_delegatecall: false
    }
  end

  @spec genesis_accounts() :: [{binary(), Account.t()}]
  def genesis_accounts() do
    accountant = 0x96CDE043E986040CB13FFAFD80EB8CEAC196FB84

    std = [
      # The Accountant
      addr_balance(accountant, ether(100_000)),
      # The Faucet
      addr_balance(0xBADA81FAE68925FEC725790C34B68B5FACA90D45, ether(100_000)),
      # Reserved A-D
      addr_balance(0x34E3961098DE3348B465CC82791BD0F7EBCE3ECD, ether(100_000)),
      addr_balance(0xC0C416B326133D74335E6828D558EFE315BD597E, ether(100_000)),
      addr_balance(0x58CC80F5526594F07F33FD4BE4AEF153BAB602B2, ether(100_000)),
      addr_balance(0x45AA0730CF4216F7195FC1F5903A171A1FAA5209, ether(100_000)),
      # alpha, beta, gamma
      addr_balance(0x937C492A77AE90DE971986D003FFBC5F8BB2232C, ether(50_000)),
      addr_balance(0xCECA2F8CF1983B4CF0C1BA51FD382C2BC37ABA58, ether(50_000)),
      addr_balance(0x68E0BAFDDA9EF323F692FC080D612718C941D120, ether(50_000)),

      # The Registry with the accountant placed
      addr_account(
        Diode.registry_address(),
        Account.new(
          balance: ether(100_000_000),
          code: Contract.Registry.test_code()
        )
        |> Account.storage_set_value(1, accountant)
      ),

      # The Fleet with the operator and accountant placed
      addr_account(
        Diode.fleet_address(),
        Account.new(
          balance: 0,
          code: Contract.Fleet.code()
        )
        |> Account.storage_set_value(0, Diode.registry_address() |> :binary.decode_unsigned())
        |> Account.storage_set_value(2, accountant)
      )
    ]

    std ++
      Enum.map(Diode.wallets(), fn wallet ->
        {Wallet.address!(wallet), Account.new(balance: ether(100_000_000))}
      end)
  end

  @spec genesis_transactions(Wallet.t()) :: [Chain.Transaction.t()]
  def genesis_transactions(miner) do
    # Call "blockReward()":
    priv = miner |> Wallet.privkey!()

    tx =
      %Chain.Transaction{
        nonce: 0,
        gasPrice: 0,
        gasLimit: 1_000_000_000,
        to: Diode.registry_address(),
        data: ABI.encode_spec("blockReward"),
        chain_id: network(0).chain_id
      }
      |> Chain.Transaction.sign(priv)

    [tx]
  end

  @spec genesis_timestamp :: non_neg_integer()
  def genesis_timestamp() do
    1_597_824_229
  end

  @spec genesis_miner :: Wallet.t()
  def genesis_miner() do
    Wallet.from_privkey(
      <<149, 210, 74, 221, 235, 25, 240, 87, 85, 95, 119, 147, 106, 182, 149, 28, 112, 227, 22,
        173, 235, 134, 113, 172, 125, 222, 191, 154, 120, 128, 129, 203>>
    )
  end

  @spec genesis_pre_hash :: <<_::256>>
  def genesis_pre_hash() do
    "0Z0Z0Z0Z0Z0Z0Z0Z0Z0Z0Z0Z0Z0Z0Z0Z"
  end

  def hardforks(block) do
    block
  end

  defp addr_balance(address, balance) do
    addr_account(address, Account.new(balance: balance))
  end

  defp addr_account(address, account) do
    {addr(address), account}
  end

  # Normalizes bignum and binary addresses -> binary
  defp addr(addr) do
    Wallet.from_address(addr) |> Wallet.address!()
  end

  defp ether(x) do
    Shell.ether(x)
  end
end

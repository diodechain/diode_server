# Diode Server
# Copyright 2019 IoT Blockchain Technology Corporation LLC (IBTC)
# Licensed under the Diode License, Version 1.0
defmodule Chain.GenesisFactory do
  alias Chain.Account, as: Account

  @spec testnet() :: Chain.Block.t()
  def testnet() do
    genesis(genesis_accounts(), genesis_transactions(genesis_miner()), genesis_miner())
  end

  def testnet_parent() do
    genesis_parent(genesis_state(genesis_accounts()), genesis_miner())
  end

  def genesis_state(accounts) do
    Enum.reduce(accounts, Chain.State.new(), fn {address, user_account}, state ->
      Chain.State.set_account(state, address, user_account)
    end)
  end

  # Normalizes bignum and binary addresses -> binary
  defp addr(addr) do
    Wallet.from_address(addr) |> Wallet.address!()
  end

  defp addr_balance(address, balance) do
    addr_account(address, Account.new(balance: balance))
  end

  defp addr_account(address, account) do
    {addr(address), account}
  end

  @spec genesis_accounts() :: [{binary(), Account.t()}]
  def genesis_accounts() do
    if Diode.dev_mode?() do
      test_genesis_accounts()
    else
      prod_genesis_accounts()
    end
  end

  def prod_genesis_accounts() do
    File.read!("data/genesis.bin") |> Chain.State.from_binary() |> Chain.State.accounts()
  end

  def test_genesis_accounts() do
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
        {Wallet.address!(wallet), Account.new(balance: ether(1000))}
      end)
  end

  def genesis_miner() do
    Wallet.from_privkey(
      <<149, 210, 74, 221, 235, 25, 240, 87, 85, 95, 119, 147, 106, 182, 149, 28, 112, 227, 22,
        173, 235, 134, 113, 172, 125, 222, 191, 154, 120, 128, 129, 203>>
    )
  end

  @spec genesis_transactions(Wallet.t()) :: [Chain.Transaction.t(), ...]
  def genesis_transactions(miner) do
    if Diode.dev_mode?() do
      test_genesis_transactions(miner)
    else
      []
    end
  end

  def test_genesis_transactions(miner) do
    # Call "blockReward()":
    priv = miner |> Wallet.privkey!()

    tx =
      %Chain.Transaction{
        nonce: 0,
        gasPrice: 0,
        gasLimit: 1_000_000_000,
        to: Diode.registry_address(),
        data: ABI.encode_spec("blockReward")
      }
      |> Chain.Transaction.sign(priv)

    [tx]
  end

  @spec genesis_parent(Chain.State.t(), Wallet.t()) :: Chain.Block.t()
  def genesis_parent(state, miner) do
    %Chain.Block{
      header: %Chain.Header{
        number: -1,
        block_hash: Chain.pre_genesis_hash(),
        state_hash: state
      },
      coinbase: miner
    }
  end

  @spec genesis(any(), [Chain.Transaction.t()], Wallet.t()) :: Chain.Block.t()
  def genesis(accounts, transactions, miner) do
    state = genesis_state(accounts)
    parent = genesis_parent(state, miner)
    block = Chain.Block.create(parent, transactions, miner, 1_579_779_937)

    header = Chain.Block.header(block)

    header =
      %{header | miner_signature: <<0::520>>}
      |> Chain.Header.update_hash()

    %{block | header: header}
  end

  defp ether(x) do
    Shell.ether(x)
  end
end

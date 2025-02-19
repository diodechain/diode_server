defmodule Job.ExportAccounts do
  @names [
           {"BURNED", "0x0000000000000000000000000000000000000000"},
           {"BURNED", "0x000000000000000000000000000000000000dead"},
           {"BURNED", "0x5000000000000000000000000000000000000000"},
           {"Corp", "0x79856ddbac41d247eacd5576a53d16965c86f7e3"},
           {"EarlyTeam", "0x21c9dB5964A9884A2E5FCFF1F959522D66F04089"},
           {"EarlyTeam", "0x295cbb9d3c13ab45a1586d7f9788e1cf87b9d036"},
           {"EarlyTeam", "0x8107A72B08309BBa63DFFCd6A6f531B1450C29A0"},
           {"EarlyTeam", "0x9c8eBD0dAedE67245F6F71C74f28174842Ea78Be"},
           {"EarlyTeam", "0xcFdB4CF5d059fc91277d664C35A40c82EA6AA05d"},
           {"EarlyTeam", "0xF1477Ef2F73d14B8aA412bD6b5cb8E96B4B70AA6"},
           {"EarlyTeam", "0xFEC19FA3501Be5244AF6cE096a1ea384271aA5d3"},
           {"Foundation_Accountant", "0x96cde043e986040cb13ffafd80eb8ceac196fb84"},
           {"Foundation_AS1", "0x68e0bafdda9ef323f692fc080d612718c941d120"},
           {"Foundation_AS2", "0x1350d3b501d6842ed881b59de4b95b27372bfae8"},
           {"Foundation_AS3", "0xefbb6a0100e7df2f6e668f2f9e6551ece12b6f01"},
           {"Foundation_EU1", "0x937c492a77ae90de971986d003ffbc5f8bb2232c"},
           {"Foundation_EU2", "0xae699211c62156b8f29ce17be47d2f069a27f2a6"},
           {"Foundation_Faucet_1", "0xbada81fae68925fec725790c34b68b5faca90d45"},
           {"Foundation_Faucet_2", "0x34e3961098de3348b465cc82791bd0f7ebce3ecd"},
           {"Foundation_Faucet_3", "0xc0c416b326133d74335e6828d558efe315bd597e"},
           {"Foundation_Faucet_4", "0x58cc80f5526594f07f33fd4be4aef153bab602b2"},
           {"Foundation_Faucet_5", "0x45aa0730cf4216f7195fc1f5903a171a1faa5209"},
           {"Foundation_Multisig", "0x1000000000000000000000000000000000000000"},
           {"Foundation_US1", "0xceca2f8cf1983b4cf0c1ba51fd382c2bc37aba58"},
           {"Foundation_US2", "0x7e4cd38d266902444dc9c8f7c0aa716a32497d0b"},
           {"Community_MoonbeamBridge", "0x2C303A315A1EE4C377E28121BAF30146E229731B"}
         ]
         |> Enum.map(fn {name, address} -> {Base16.decode(address), name} end)
         |> Map.new()

  def names() do
    @names
  end

  def name(address) do
    Map.get(@names, address, "_")
  end

  def fmt(x) do
    x
    |> Integer.to_charlist()
    |> Enum.reverse()
    |> Enum.chunk_every(3)
    |> Enum.join(",")
    |> String.reverse()
  end

  def accs(block) do
    BlockProcess.with_state(block, fn state -> Chain.State.accounts(state) end)
  end

  @separator ";"
  def run(opts \\ []) do
    include_burned = Keyword.get(opts, :include_burned, false)
    block = Chain.peak()

    fp = File.open!("accounts_#{block}.csv", [:write])

    log =
      [
        "Address",
        "Name",
        "Group",
        "TotalDiode",
        "BalanceWei",
        "MinerStakedWei",
        "MinerUnstakedWei",
        "ContractStakedWei",
        "ContractUnstakedWei"
      ]
      |> Enum.join(@separator)

    IO.puts(log)
    IO.puts(fp, log)

    Enum.map(accs(block), fn {key, acc} ->
      name = name(key)
      balance = Chain.Account.balance(acc)
      {m_staked, m_unstaked} = Contract.Registry.miner_value_slot(key, block)
      {c_staked, c_unstaked} = Contract.Registry.contract_value_slot(key, block)
      total = balance + m_staked + m_unstaked + c_staked + c_unstaked

      %{
        name: name,
        address: key,
        balance: balance,
        m_staked: m_staked,
        m_unstaked: m_unstaked,
        c_staked: c_staked,
        c_unstaked: c_unstaked,
        total: total
      }
    end)
    |> Enum.filter(fn %{total: total} -> total > 0 end)
    |> Enum.filter(fn %{name: name} ->
      include_burned || name != "BURNED"
    end)
    |> Enum.sort_by(& &1.total, :desc)
    |> Enum.each(fn %{
                      name: name,
                      address: key,
                      balance: balance,
                      m_staked: m_staked,
                      m_unstaked: m_unstaked,
                      c_staked: c_staked,
                      c_unstaked: c_unstaked,
                      total: total
                    } ->
      total_diode = div(total, 1_000_000_000_000_000_000)

      {name, group} =
        case String.split(name, "_", parts: 2, trim: true) do
          [] -> {"_", "Community"}
          [name] -> {name, name}
          [group, name] -> {name, group}
        end

      log =
        [
          Base16.encode(key),
          name,
          group,
          fmt(total_diode),
          fmt(balance),
          fmt(m_staked),
          fmt(m_unstaked),
          fmt(c_staked),
          fmt(c_unstaked)
        ]
        |> Enum.join(@separator)

      IO.puts(log)
      IO.puts(fp, log)
    end)

    File.close(fp)
  end
end

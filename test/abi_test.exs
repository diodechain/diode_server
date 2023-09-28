# Diode Server
# Copyright 2021 Diode
# Licensed under the Diode License, Version 1.1
defmodule ABITest do
  use ExUnit.Case

  test "reference" do
    assert EIP712.encode_single_type("Person", [
             {"name", "string"},
             {"wallet", "address"}
           ]) == "Person(string name,address wallet)"

    assert hex(
             EIP712.type_hash("Person", %{
               "Person" => [
                 {"name", "string"},
                 {"wallet", "address"}
               ]
             })
           ) == "0xb9d8c78acf9b987311de6c7b45bb6a9c8e1bf361fa7fd3467a2163f994c79500"

    assert EIP712.encode_single_type("EIP712Domain", [
             {"name", "string"},
             {"version", "string"},
             {"chainId", "uint256"},
             {"verifyingContract", "address"}
           ]) ==
             "EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"

    assert EIP712.encode_type("Transaction", %{
             "Transaction" => [
               {"from", "Person"},
               {"to", "Person"},
               {"tx", "Asset"}
             ],
             "Person" => [
               {"wallet", "address"},
               {"name", "string"}
             ],
             "Asset" => [
               {"token", "address"},
               {"amount", "uint256"}
             ]
           }) ==
             "Transaction(Person from,Person to,Asset tx)Asset(address token,uint256 amount)Person(address wallet,string name)"

    domain_separator =
      EIP712.hash_struct("EIP712Domain", [
        {"name", "string", "Ether Mail"},
        {"version", "string", "1"},
        {"chainId", "uint256", 1},
        {"verifyingContract", "address", unhex("0xCcCCccccCCCCcCCCCCCcCcCccCcCCCcCcccccccC")}
      ])

    assert hex(domain_separator) ==
             "0xf2cee375fa42b42143804025fc449deafd50cc031ca257e0b194a650a912090f"

    assert EIP712.hash_domain_separator(
             "Ether Mail",
             "1",
             1,
             unhex("0xCcCCccccCCCCcCCCCCCcCcCccCcCCCcCcccccccC")
           ) == domain_separator

    assert hex(
             EIP712.encode(domain_separator, "Person", [
               {"name", "string", "Bob"},
               {"wallet", "address", unhex("0xbBbBBBBbbBBBbbbBbbBbbbbBBbBbbbbBbBbbBBbB")}
             ])
           ) == "0x0a94cf6625e5860fc4f330d75bcd0c3a4737957d2321d1a024540ab5320fe903"
  end

  test "eip-712" do
    cow = Wallet.from_privkey(Hash.keccak_256("cow"))
    assert hex(Wallet.address!(cow)) == "0xcd2a3d9f938e13cd947ec05abc7fe734df8dd826"

    type_data = %{
      "Person" => [
        {"name", "string"},
        {"wallet", "address"}
      ],
      "Mail" => [
        {"from", "Person"},
        {"to", "Person"},
        {"contents", "string"}
      ]
    }

    domain_separator =
      EIP712.hash_domain_separator(
        "Ether Mail",
        "1",
        1,
        unhex("0xCcCCccccCCCCcCCCCCCcCcCccCcCCCcCcccccccC")
      )

    digest =
      EIP712.encode(domain_separator, "Mail", type_data, %{
        "from" => %{
          "name" => "Cow",
          "wallet" => unhex("0xCD2a3d9F938E13CD947Ec05AbC7FE734Df8DD826")
        },
        "to" => %{
          "name" => "Bob",
          "wallet" => unhex("0xbBbBBBBbbBBBbbbBbbBbbbbBBbBbbbbBbBbbBBbB")
        },
        "contents" => "Hello, Bob!"
      })

    assert hex(Wallet.eth_sign!(cow, digest, nil, :none)) ==
             "0x4355c47d63924e8a72e509b65029052eb6c299d53a04e167c5775fd466751c9d07299936d304c153f6443dfa05f40ff007d72911b6f72307f996231605b915621c"
  end

  defp hex(x), do: Base16.encode(x)
  defp unhex(x), do: Base16.decode(x)
end

# Diode Server
# Copyright 2021-2024 Diode
# Licensed under the Diode License, Version 1.1
defmodule RlpTest do
  use ExUnit.Case

  test "short list" do
    {public, private} = Secp256k1.generate()
    random = "hello world"

    term = [public, private, random]
    bin = Rlp.encode!(term)
    assert term == Rlp.decode!(bin)

    term = [public, private, [random]]
    bin = Rlp.encode!(term)
    assert term == Rlp.decode!(bin)

    term = List.duplicate(random, 1000)
    bin = Rlp.encode!(term)
    assert term == Rlp.decode!(bin)
  end

  test "strings" do
    short = "hello world"
    long = String.duplicate(short, 1000)

    term = [long]
    bin = Rlp.encode!(term)
    assert term == Rlp.decode!(bin)

    term = long
    bin = Rlp.encode!(term)
    assert term == Rlp.decode!(bin)

    term = [short]
    bin = Rlp.encode!(term)
    assert term == Rlp.decode!(bin)

    term = short
    bin = Rlp.encode!(term)
    assert term == Rlp.decode!(bin)
  end

  test "0 - 256" do
    for n <- 0..256 do
      list = List.duplicate([], n)
      assert Rlp.decode!(Rlp.encode!(list)) == list

      bin = String.duplicate("_", n)
      assert Rlp.decode!(Rlp.encode!(bin)) == bin
    end
  end

  test "nil, 0" do
    in_term = [0, <<0>>, nil, ""]
    out_term = ["", <<0>>, "", ""]
    assert out_term == Rlp.decode!(Rlp.encode!(in_term))
  end

  test "rlp => app => rlp" do
    bin =
      :binary.encode_unsigned(
        0xF86708843B9ACA0082A2A0949E0A6D367859C47E7895557D5F763B954952FCB08084D09DE08A1CA0F40915BA7822D7CDA5C42B530E21616249E700082A4E7401E8C62775E7C5E219A01BE95441D88652AE5ED7E57ECF837EB1DDF844024E55E5EFB6CD2AA555C913DD
        # 0xF86708843B9ACA0082A2A0949E0A6D367859C47E7895557D5F763B954952FCB08084D09DE08A2CA0F40915BA7822D7CDA5C42B530E21616249E700082A4E7401E8C62775E7C5E219A01BE95441D88652AE5ED7E57ECF837EB1DDF844024E55E5EFB6CD2AA555C913DD
      )

    tx = Chain.Transaction.from_rlp(bin)
    bin2 = Rlp.encode!(Chain.Transaction.to_rlp(tx))
    assert bin == bin2
  end
end

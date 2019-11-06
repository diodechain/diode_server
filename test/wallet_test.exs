# Diode Server
# Copyright 2019 IoT Blockchain Technology Corporation LLC (IBTC)
# Licensed under the Diode License, Version 1.0
defmodule WalletTest do
  use ExUnit.Case

  test "simple" do
    {pub, priv} = Secp256k1.generate()
    pub_compressed = Secp256k1.compress_public(pub)

    w1 = Wallet.from_pubkey(pub)
    w2 = Wallet.from_privkey(priv)
    w3 = Wallet.from_address(Wallet.address!(w1))

    assert Wallet.address!(w1) == Wallet.address!(w2)
    assert Wallet.address!(w3) == Wallet.address!(w2)
    assert Wallet.pubkey!(w1) == Wallet.pubkey!(w2)

    assert {:error, nil} == Wallet.privkey(w1)
    assert {:ok, pub_compressed} == Wallet.pubkey(w1)

    assert {:ok, priv} == Wallet.privkey(w2)

    assert {:error, nil} == Wallet.privkey(w3)
    assert {:error, nil} == Wallet.pubkey(w3)
    assert {:ok, Wallet.address!(w1)} == Wallet.address(w3)
  end
end

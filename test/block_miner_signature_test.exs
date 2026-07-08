# Diode Server
# Copyright 2021-2024 Diode
# Licensed under the Diode License, Version 1.1
defmodule BlockMinerSignatureTest do
  use ExUnit.Case, async: true

  alias Chain.{Block, Header}

  defp block(sig) do
    %Block{
      coinbase: nil,
      header: %Header{
        number: 11_188_096,
        miner_signature: sig,
        block_hash: <<1::256>>
      }
    }
  end

  test "miner_signature_valid? rejects nil, empty, and zero signatures" do
    refute Block.miner_signature_valid?(block(nil))
    refute Block.miner_signature_valid?(block(<<>>))
    refute Block.miner_signature_valid?(block(<<0::520>>))
  end

  test "miner_signature_valid? accepts non-zero signatures" do
    assert Block.miner_signature_valid?(block(<<1, 2, 3, 4>>))
  end

  test "sync_wire_reject_reason includes block number and signature state" do
    msg = Block.sync_wire_reject_reason(block(nil))
    assert msg =~ "11188096"
    assert msg =~ "missing miner_signature (nil)"
  end
end

defmodule Secp256k1Test do
  use ExUnit.Case

  test "generate" do
    {public, private} = Secp256k1.generate()

    assert byte_size(public) == 65
    assert byte_size(private) == 32
  end

  test "signature" do
    {public1, private1} = Secp256k1.generate()
    {public2, private2} = Secp256k1.generate()
    msg = "hello world"

    signature1 = Secp256k1.sign(private1, msg)
    signature2 = Secp256k1.sign(private2, msg)

    assert byte_size(signature1) == 65
    assert byte_size(signature2) == 65

    assert Secp256k1.verify(public1, msg, signature1) == true
    assert Secp256k1.verify(public2, msg, signature2) == true

    assert Secp256k1.verify(public1, msg, signature2) == false
    assert Secp256k1.verify(public2, msg, signature1) == false
  end

  test "recover" do
    {public, private} = Secp256k1.generate()
    public = Secp256k1.compress_public(public)

    msg = "hello world"
    signature = Secp256k1.sign(private, msg)

    assert Secp256k1.recover!(signature, msg) == public
  end
end

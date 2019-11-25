# Diode Server
# Copyright 2019 IoT Blockchain Technology Corporation LLC (IBTC)
# Licensed under the Diode License, Version 1.0
defmodule Secp256k1 do
  import Wallet

  @type private_key :: <<_::256>>
  @type compressed_public_key :: <<_::264>>
  @type full_public_key :: <<_::520>>
  @type public_key :: compressed_public_key() | full_public_key()
  @type signature :: <<_::520>>

  @cut 0xFFFFFFFF_FFFFFFFF_FFFFFFFF_FFFFFFFF_FFFFFFFF_FFFFFFFF_FFFFFFFF_FFFFFFFF
  @full 0xFFFFFFFF_FFFFFFFF_FFFFFFFF_FFFFFFFE_BAAEDCE6_AF48A03B_BFD25E8C_D0364141
  @half 0x7FFFFFFF_FFFFFFFF_FFFFFFFF_FFFFFFFF_5D576E73_57A4501D_DFE92F46_681B20A0

  @doc "Returns {PublicKey, PrivKeyOut}"
  @spec generate() :: {public_key(), private_key()}
  def generate() do
    {public, private} = :crypto.generate_key(:ecdh, :secp256k1)
    private = :binary.decode_unsigned(private)
    {public, <<private::unsigned-size(256)>>}

    # We cannot compress here because openssl can't deal with compressed
    # points in TLS handshake, should report a bug
    # {compress_public(public), private}
  end

  def generate_public_key(private_key) do
    :libsecp256k1.ec_pubkey_create(private_key, :uncompressed)
  end

  @spec compress_public(public_key()) :: compressed_public_key()
  def compress_public(public) do
    case public do
      <<4, x::big-integer-size(256), y::big-integer-size(256)>> ->
        ## Compressing point
        ## Check http://www.secg.org/SEC1-Ver-1.0.pdf page 11
        ##
        ref = 2 + rem(y, 2)
        <<ref, x::big-integer-size(256)>>

      <<ref, x::big-integer-size(256)>> ->
        <<ref, x::big-integer-size(256)>>
    end
  end

  @spec decompress_public(compressed_public_key()) :: public_key()
  def decompress_public(public) do
    {:ok, public} = :libsecp256k1.ec_pubkey_decompress(public)
    public
  end

  def der_encode_private(private, public) do
    :public_key.der_encode(:ECPrivateKey, erl_encode_private(private, public))
  end

  def pem_encode_private(private, public) do
    :public_key.pem_encode([
      {:ECPrivateKey, der_encode_private(private, public), :not_encrypted}
    ])
  end

  def erl_encode_private(private, public) do
    {:ECPrivateKey, 1, private, curve_params(), public}
  end

  def selfsigned(private, public) do
    :public_key.pkix_sign(
      erl_encode_cert(public),
      erl_encode_private(private, public)
    )
  end

  @spec sign(private_key(), binary(), :sha | :kec) :: signature()
  def sign(private, msg, algo \\ :sha) do
    {:ok, signature, recid} =
      :libsecp256k1.ecdsa_sign_compact(hash(algo, msg), private, :default, "")

    <<recid, signature::binary>>
  end

  @spec verify(public_key() | Wallet.t(), binary(), signature()) :: boolean()
  def verify(public, msg, signature) when is_binary(public) do
    # :ok == :libsecp256k1.ecdsa_verify(msg, signature_bitcoin_to_x509(signature), public)
    # Verify with openssl for now
    x509 = signature_bitcoin_to_x509(signature)
    :crypto.verify(:ecdsa, :sha256, msg, x509, [public, :crypto.ec_curve(:secp256k1)])
  end

  def verify(public = wallet(), msg, signature) do
    signer = recover!(signature, msg)

    verify(signer, msg, signature) &&
      Wallet.address!(Wallet.from_pubkey(signer)) == Wallet.address!(public)
  end

  @spec recover!(signature(), binary(), :sha | :kec | :none) :: public_key()
  def recover!(signature, msg, algo \\ :sha) do
    {:ok, public} = recover(signature, msg, algo)
    public
  end

  @spec recover(signature(), binary(), :sha | :kec | :none) ::
          {:ok, public_key()} | {:error, String.t()}
  def recover(signature, msg, algo \\ :sha) do
    <<recid, signature::binary>> = signature
    :libsecp256k1.ecdsa_recover_compact(hash(algo, msg), signature, :compressed, recid)
  end

  @spec rlp_to_bitcoin(binary, binary, binary) :: nil | <<_::520>>
  def rlp_to_bitcoin("", "", "") do
    nil
  end

  def rlp_to_bitcoin(rec, r, s)
      when is_binary(rec) and byte_size(r) <= 32 and byte_size(s) <= 32 do
    rec = :binary.decode_unsigned(rec, :big)
    rec = 1 - rem(rec, 2)
    r = :binary.decode_unsigned(r, :big)
    s = :binary.decode_unsigned(s, :big)
    <<rec::little-unsigned, r::big-unsigned-size(256), s::big-unsigned-size(256)>>
  end

  def chain_id(rec) when is_binary(rec) do
    rec = :binary.decode_unsigned(rec, :big)

    if rec >= 35 do
      odd = 1 - rem(rec, 2)
      div(rec - (35 + odd), 2)
    else
      nil
    end
  end

  def bitcoin_to_rlp(signature, chain_id \\ nil)

  def bitcoin_to_rlp(<<rec, r::big-unsigned-size(256), s::big-unsigned-size(256)>>, nil) do
    [rec + 27, r, s]
  end

  def bitcoin_to_rlp(<<rec, r::big-unsigned-size(256), s::big-unsigned-size(256)>>, chain_id) do
    # EIP-155
    [chain_id * 2 + rec + 35, r, s]
  end

  @doc "Converts X.509 signature to bitcoin style signature"
  def signature_x509_to_bitcoin(signature) do
    {_, r, s} = :public_key.der_decode(:"ECDSA-Sig-Value", signature)

    # Important! This we only accept normalized signatures ever!
    s = normalize(s)

    # Garbage currently
    rec = 27
    # https://github.com/bitcoin/bitcoin/blob/master/src/key.cpp:252
    # vchSig[0] = 27 + rec + (fCompressed ? 4 : 0);

    <<rec, r::big-unsigned-size(256), s::big-unsigned-size(256)>>
  end

  defp normalize(n) do
    if n > @half do
      rem(@cut - n + @full, @cut)
    else
      n
    end
  end

  def signature_bitcoin_to_x509(<<_, r::big-unsigned-size(256), s::big-unsigned-size(256)>>) do
    :public_key.der_encode(:"ECDSA-Sig-Value", {:"ECDSA-Sig-Value", r, s})
  end

  @spec erl_encode_cert(public_key()) :: any()
  def erl_encode_cert(public) do
    hash = hash(:sha, public)

    {:OTPTBSCertificate, :v3, 9_671_339_679_901_102_673,
     {:SignatureAlgorithm, {1, 2, 840, 10045, 4, 3, 2}, :asn1_NOVALUE},
     {:rdnSequence,
      [
        [{:AttributeTypeAndValue, {2, 5, 4, 6}, 'US'}],
        [{:AttributeTypeAndValue, {2, 5, 4, 8}, {:utf8String, "Oregon"}}],
        [{:AttributeTypeAndValue, {2, 5, 4, 7}, {:utf8String, "Portland"}}],
        [{:AttributeTypeAndValue, {2, 5, 4, 10}, {:utf8String, "Company Name"}}],
        [{:AttributeTypeAndValue, {2, 5, 4, 11}, {:utf8String, "Org"}}],
        [{:AttributeTypeAndValue, {2, 5, 4, 3}, {:utf8String, "www.example.com"}}]
      ]}, {:Validity, {:utcTime, '181113072916Z'}, {:utcTime, '231113072916Z'}},
     {:rdnSequence,
      [
        [{:AttributeTypeAndValue, {2, 5, 4, 6}, 'US'}],
        [{:AttributeTypeAndValue, {2, 5, 4, 8}, {:utf8String, "Oregon"}}],
        [{:AttributeTypeAndValue, {2, 5, 4, 7}, {:utf8String, "Portland"}}],
        [{:AttributeTypeAndValue, {2, 5, 4, 10}, {:utf8String, "Company Name"}}],
        [{:AttributeTypeAndValue, {2, 5, 4, 11}, {:utf8String, "Org"}}],
        [{:AttributeTypeAndValue, {2, 5, 4, 3}, {:utf8String, "www.example.com"}}]
      ]},
     {:OTPSubjectPublicKeyInfo, {:PublicKeyAlgorithm, {1, 2, 840, 10045, 2, 1}, curve_params()},
      {:ECPoint, public}}, :asn1_NOVALUE, :asn1_NOVALUE,
     [
       # Identifier: Subject Key Identifier - 2.5.29.14
       {:Extension, {2, 5, 29, 14}, false, hash},
       # Identifier: Authority Key Identifier - 2.5.29.35
       {:Extension, {2, 5, 29, 35}, false,
        {:AuthorityKeyIdentifier, hash, :asn1_NOVALUE, :asn1_NOVALUE}},
       {:Extension, {2, 5, 29, 19}, true, {:BasicConstraints, true, :asn1_NOVALUE}}
     ]}
  end

  defp curve_params(), do: {:namedCurve, {1, 3, 132, 0, 10}}

  defp hash(:none, <<msg::binary-size(32)>>) do
    msg
  end

  defp hash(:sha, msg) do
    Hash.sha3_256(msg)
  end

  defp hash(:kec, msg) do
    Hash.keccak_256(msg)
  end
end

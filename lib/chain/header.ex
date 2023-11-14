# Diode Server
# Copyright 2021-2024 Diode
# Licensed under the Diode License, Version 1.1
defmodule Chain.Header do
  import Wallet

  defstruct previous_block: nil,
            miner_signature: nil,
            block_hash: nil,
            state_hash: nil,
            transaction_hash: nil,
            timestamp: 0,
            number: 0,
            nonce: 0

  @type t :: %Chain.Header{
          previous_block: binary() | nil,
          miner_signature: binary() | nil,
          block_hash: binary() | nil,
          state_hash: binary() | nil | Chain.State.t(),
          transaction_hash: binary() | nil,
          timestamp: non_neg_integer(),
          number: integer(),
          nonce: non_neg_integer()
        }

  # egg is everything but the miner_signature and the block hash, it is required to create the miner_signature
  defp encode_egg(
         %Chain.Header{
           previous_block: prev_block,
           transaction_hash: tx_hash,
           timestamp: timestamp,
           number: number,
           nonce: nonce
         } = header
       ) do
    term = [
      prev_block,
      state_hash(header),
      tx_hash,
      timestamp,
      number,
      nonce
    ]

    :erlang.term_to_binary(term, minor_version: 1)
  end

  # chicken is everything but the block hash, it is required to create the block hash
  defp encode_chicken(
         %Chain.Header{
           previous_block: prev_block,
           transaction_hash: tx_hash,
           timestamp: timestamp,
           number: number,
           nonce: nonce,
           miner_signature: miner_signature
         } = header
       ) do
    term = [
      prev_block,
      state_hash(header),
      tx_hash,
      timestamp,
      number,
      nonce,
      miner_signature
    ]

    :erlang.term_to_binary(term, minor_version: 1)
  end

  @spec update_hash(Chain.Header.t()) :: Chain.Header.t()
  def update_hash(%Chain.Header{} = header) do
    %{header | block_hash: Diode.hash(encode_chicken(header))}
  end

  @spec sign(Chain.Header.t(), Wallet.t()) :: Chain.Header.t()
  def sign(%Chain.Header{} = header, wallet() = miner) do
    %{header | miner_signature: Secp256k1.sign(Wallet.privkey!(miner), encode_egg(header))}
  end

  def state_hash(%Chain.Header{state_hash: %Chain.State{} = state}), do: Chain.State.hash(state)
  def state_hash(%Chain.Header{state_hash: state_hash}), do: state_hash

  def recover_miner(header) do
    case :binary.decode_unsigned(header.miner_signature || "") do
      0 ->
        Wallet.from_address(<<0::160>>)

      _ ->
        Secp256k1.recover!(header.miner_signature, encode_egg(header))
        |> Wallet.from_pubkey()
    end
  end

  def strip_state(header) do
    %{header | state_hash: state_hash(header)}
  end
end

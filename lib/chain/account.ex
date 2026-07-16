# Diode Server
# Copyright 2021-2024 Diode
# Licensed under the Diode License, Version 1.1
defmodule Chain.Account do
  defstruct nonce: 0, balance: 0, storage_root: nil, code: nil, map_backed: false, root_hash: nil

  # Matches C++ empty storage trie root (root_hash of an empty storage trie).
  @empty_storage_root Base.decode16!(
                        "438A90405DAA876539082CD0BAF6CDDAA3BF880F1C8AF0C0381F0042DB93088A"
                      )

  @type t :: %Chain.Account{
          nonce: non_neg_integer(),
          balance: non_neg_integer(),
          storage_root: nil | reference() | [{binary(), binary()}],
          code: binary() | nil,
          map_backed: boolean(),
          root_hash: binary() | nil
        }

  def new(props \\ []) do
    acc = %Chain.Account{}

    Enum.reduce(props, acc, fn {key, value}, acc ->
      Map.put(acc, key, value)
    end)
  end

  def code(%Chain.Account{code: nil}), do: ""
  def code(%Chain.Account{code: code}), do: code
  def nonce(%Chain.Account{nonce: nonce}), do: nonce
  def balance(%Chain.Account{balance: balance}), do: balance

  @doc """
  Build an account from `CAccountMap.get/2` parts.
  A 32-byte `storage` root marks the account map-backed (`map_backed: true`).
  Otherwise `storage` is a put payload (`nil` / slot list / resource for `set_account`).
  """
  def from_parts(nonce, balance, <<root_hash::binary-size(32)>>, code) do
    %Chain.Account{
      nonce: nonce,
      balance: balance,
      storage_root: nil,
      code: if(code == "", do: nil, else: code),
      map_backed: true,
      root_hash: root_hash
    }
  end

  def from_parts(nonce, balance, storage, code) do
    %Chain.Account{
      nonce: nonce,
      balance: balance,
      storage_root: storage,
      code: if(code == "", do: nil, else: code),
      map_backed: false,
      root_hash: nil
    }
  end

  def root_hash(%Chain.Account{root_hash: <<_::binary-size(32)>> = hash}), do: hash

  def root_hash(%Chain.Account{storage_root: nil}), do: @empty_storage_root

  def root_hash(%Chain.Account{}) do
    raise ArgumentError,
          "account missing :root_hash; use Chain.State.storage_root_hash/2"
  end

  @spec to_rlp(Chain.Account.t()) :: [...]
  def to_rlp(%Chain.Account{} = account) do
    [
      account.nonce,
      account.balance,
      root_hash(account),
      codehash(account)
    ]
  end

  @spec hash(Chain.Account.t()) :: binary()
  def hash(%Chain.Account{} = account) do
    Diode.hash(Rlp.encode!(to_rlp(account)))
  end

  @empty_hash Diode.hash("")
  def codehash(%Chain.Account{code: nil}) do
    @empty_hash
  end

  def codehash(%Chain.Account{code: code}) do
    Diode.hash(code)
  end
end

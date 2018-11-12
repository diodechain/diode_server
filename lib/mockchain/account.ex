defmodule Mockchain.Account do
  defstruct nonce: 0, balance: 0, storageRoot: MerkleTree.new(), code: nil

  @type t :: %Mockchain.Account{
          nonce: non_neg_integer(),
          balance: non_neg_integer()
        }

  def code(%Mockchain.Account{code: nil}), do: ""
  def code(%Mockchain.Account{code: code}), do: code
  def nonce(%Mockchain.Account{nonce: nonce}), do: nonce
  def balance(%Mockchain.Account{balance: balance}), do: balance

  def storageSetValue(
        %Mockchain.Account{storageRoot: store} = acc,
        key = <<_k::256>>,
        value = <<_v::256>>
      ) do
    store = MerkleTree.insert(store, key, value)
    %Mockchain.Account{acc | storageRoot: store}
  end

  def storageSetValue(acc, key, value) when is_integer(key) do
    storageSetValue(acc, <<key::unsigned-size(256)>>, value)
  end

  def storageSetValue(acc, key, value) when is_integer(value) do
    storageSetValue(acc, key, <<value::unsigned-size(256)>>)
  end

  @spec storageValue(Mockchain.Account.t(), binary() | integer()) :: binary() | nil
  def storageValue(acc, key) when is_integer(key) do
    storageValue(acc, <<key::unsigned-size(256)>>)
  end

  def storageValue(%Mockchain.Account{storageRoot: store}, key) when is_binary(key) do
    MerkleTree.get(store, key)
  end

  @spec storageInteger(Mockchain.Account.t(), binary() | integer()) :: non_neg_integer()
  def storageInteger(acc, key) do
    case storageValue(acc, key) do
      nil -> 0
      other -> :binary.decode_unsigned(other)
    end
  end

  @spec to_rlp(Mockchain.Account.t()) :: [...]
  def to_rlp(%Mockchain.Account{} = account) do
    [
      account.nonce,
      account.balance,
      MerkleTree.root_hash(account.storageRoot),
      codehash(account)
    ]
  end

  @spec hash(Mockchain.Account.t()) :: binary()
  def hash(%Mockchain.Account{} = account) do
    Diode.hash(Rlp.encode!(to_rlp(account)))
  end

  def codehash(%Mockchain.Account{code: nil}) do
    Diode.hash("")
  end

  def codehash(%Mockchain.Account{code: code}) do
    Diode.hash(code)
  end
end

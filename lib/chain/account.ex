defmodule Chain.Account do
  defstruct nonce: 0, balance: 0, storage_root: MerkleTree.new(), code: nil

  @type t :: %Chain.Account{
          nonce: non_neg_integer(),
          balance: non_neg_integer()
        }

  def code(%Chain.Account{code: nil}), do: ""
  def code(%Chain.Account{code: code}), do: code
  def nonce(%Chain.Account{nonce: nonce}), do: nonce
  def balance(%Chain.Account{balance: balance}), do: balance

  def storage_set_value(
        %Chain.Account{storage_root: store} = acc,
        key = <<_k::256>>,
        value = <<_v::256>>
      ) do
    store = MerkleTree.insert(store, key, value)
    %Chain.Account{acc | storage_root: store}
  end

  def storage_set_value(acc, key, value) when is_integer(key) do
    storage_set_value(acc, <<key::unsigned-size(256)>>, value)
  end

  def storage_set_value(acc, key, value) when is_integer(value) do
    storage_set_value(acc, key, <<value::unsigned-size(256)>>)
  end

  @spec storage_value(Chain.Account.t(), binary() | integer()) :: binary() | nil
  def storage_value(acc, key) when is_integer(key) do
    storage_value(acc, <<key::unsigned-size(256)>>)
  end

  def storage_value(%Chain.Account{storage_root: store}, key) when is_binary(key) do
    MerkleTree.get(store, key)
  end

  @spec storage_integer(Chain.Account.t(), binary() | integer()) :: non_neg_integer()
  def storage_integer(acc, key) do
    case storage_value(acc, key) do
      nil -> 0
      other -> :binary.decode_unsigned(other)
    end
  end

  @spec to_rlp(Chain.Account.t()) :: [...]
  def to_rlp(%Chain.Account{} = account) do
    [
      account.nonce,
      account.balance,
      MerkleTree.root_hash(account.storage_root),
      codehash(account)
    ]
  end

  @spec hash(Chain.Account.t()) :: binary()
  def hash(%Chain.Account{} = account) do
    Diode.hash(Rlp.encode!(to_rlp(account)))
  end

  def codehash(%Chain.Account{code: nil}) do
    Diode.hash("")
  end

  def codehash(%Chain.Account{code: code}) do
    Diode.hash(code)
  end
end

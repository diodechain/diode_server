defmodule Mockchain.State do
  defstruct store: MerkleTree.new(), map: %{}

  def new() do
    %Mockchain.State{store: MerkleTree.new()}
  end

  def hash(%Mockchain.State{store: tree}) do
    MerkleTree.root_hash(tree)
  end

  def accounts(%Mockchain.State{store: store, map: map}) do
    MerkleTree.to_list(store)
    |> Enum.map(fn {key, value} -> {key, Map.get(map, value)} end)
    |> Map.new()
  end

  @spec account(Mockchain.State.t(), <<_::160>>) :: Mockchain.Account.t() | nil
  def account(%Mockchain.State{store: store, map: map}, id = <<_::160>>) do
    Map.get(map, MerkleTree.get(store, id))
  end

  @spec ensure_account(Mockchain.State.t(), <<_::160>>) :: Mockchain.Account.t()
  def ensure_account(state = %Mockchain.State{}, id = <<_::160>>) do
    case account(state, id) do
      nil -> %Mockchain.Account{nonce: 0}
      acc -> acc
    end
  end

  @spec set_account(Mockchain.State.t(), binary(), Mockchain.Account.t()) :: Mockchain.State.t()
  def set_account(state = %Mockchain.State{store: store, map: map}, id = <<_::160>>, account) do
    hash = Mockchain.Account.hash(account)
    # store = MerkleTree.delete(store, id)
    store = MerkleTree.insert(store, id, hash)
    map = Map.put(map, hash, account)

    # Recreating map, ensuring to skip non-referenced entries
    map = for {_k, v} <- MerkleTree.to_list(store), into: %{}, do: {v, Map.fetch!(map, v)}
    %{state | store: store, map: map}
  end

  @spec delete_account(Mockchain.State.t(), binary()) :: Mockchain.State.t()
  def delete_account(state = %Mockchain.State{store: store, map: map}, id = <<_::160>>) do
    store = MerkleTree.delete(store, id)
    # Recreating map, ensuring to skip non-referenced entries
    map = for {_k, v} <- MerkleTree.to_list(store), into: %{}, do: {v, Map.fetch!(map, v)}
    %{state | store: store, map: map}
  end
end

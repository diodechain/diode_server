defprotocol RemoteChain.Cache do
  def get(cache, key)
  def put(cache, key, value)
end

defimpl RemoteChain.Cache, for: Lru do
  def get(cache, key), do: Lru.get(cache, key)
  def put(cache, key, value), do: Lru.insert(cache, key, value)
end

defimpl RemoteChain.Cache, for: DetsPlus do
  def get(cache, key) do
    case DetsPlus.lookup(cache, key) do
      [{^key, value}] -> value
      _ -> nil
    end
  end

  def put(cache, key, value) do
    DetsPlus.insert(cache, {key, value})
    cache
  end
end

defimpl RemoteChain.Cache, for: DetsPlus.LRU do
  def get(cache, key) do
    DetsPlus.LRU.get(cache, key)
  end

  def put(cache, key, value) do
    DetsPlus.LRU.put(cache, key, value)
    cache
  end
end

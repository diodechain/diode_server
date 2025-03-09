
{:ok, db} = Sqlitex.open("data_prod/blockchain.sq3")

Sqlitex.query!(db, "PRAGMA journal_mode = WAL")
Sqlitex.query!(db, "PRAGMA synchronous = NORMAL")
Sqlitex.query!(db, "PRAGMA AUTO_VACUUM = 1")

defmodule Recompress do
  def recompress(data) do
    case data do
      <<40, 181, 47, 253, _::binary>> ->
        :ezstd.decompress(data)
        |> :ezstd.compress(22)

      _other ->
        :zlib.unzip(data)
        |> :ezstd.compress(22)
    end
  end
end
case System.argv() do
  [start, stop] ->
    start = String.to_integer(start)
    stop = String.to_integer(stop)


    Task.async_stream(
      start..stop//100,
      fn block ->
        Sqlitex.query!(db, "SELECT number, data, state FROM blocks WHERE number > ?1 AND number <= ?1 + 100", bind: [block], timeout: :infinity)
        |> Enum.map(fn [number: number, data: data, state: state] ->
          {number, data, state}
        end)
      end,
      timeout: :infinity,
      max_concurrency: 2,
      ordered: true
    )
    |> Stream.flat_map(fn {:ok, data} ->
      data
    end)
    |> Task.async_stream(fn {block, data, state} ->
      data2 = Recompress.recompress(data)
      state2 = Recompress.recompress(state)

      if byte_size(data2) < byte_size(data) or byte_size(state2) < byte_size(state) do
        IO.puts("\tblock #{block} state size: #{byte_size(state)} => #{byte_size(state2)} data size: #{byte_size(data)} => #{byte_size(data2)}")
        Sqlitex.query!(db, "UPDATE blocks SET data = ?1, state = ?2 WHERE number = ?3", bind: [data2, state2, block])
      end
    end,
    timeout: :infinity,
    # max_concurrency: 8,
    ordered: true
  )
  |> Stream.run()
  _ ->
    :ok
end

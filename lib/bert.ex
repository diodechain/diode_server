# Diode Server
# Copyright 2021 Diode
# Licensed under the Diode License, Version 1.1
defmodule BertInt do
  @moduledoc """
  Binary Erlang Term encoding for internal node-to-node encoding.
  """
  @spec encode!(any()) :: binary()
  def encode!(term) do
    term
    |> :erlang.term_to_binary()
    |> zip()
  end

  # Custom impl of :zlib.zip() for faster compression
  defp zip(data, level \\ 1) do
    z = :zlib.open()

    bs =
      try do
        :zlib.deflateInit(z, level, :deflated, -15, 8, :default)
        b = :zlib.deflate(z, data, :finish)
        :zlib.deflateEnd(z)
        b
      after
        :zlib.close(z)
      end

    :erlang.iolist_to_binary(bs)
  end

  @spec decode!(binary()) :: any()
  def decode!(term) do
    try do
      :zlib.unzip(term)
    rescue
      [ErlangError, :data_error] ->
        term
    end
    |> :erlang.binary_to_term()
  end

  @doc """
    decode! variant for decoding locally created files, can decode atoms.
  """
  def decode_unsafe!(term) do
    try do
      :zlib.unzip(term)
    rescue
      [ErlangError, :data_error] ->
        term
    end
    |> :erlang.binary_to_term()
  end
end

defmodule BertExt do
  @spec encode!(any()) :: binary()
  def encode!(term) do
    :erlang.term_to_binary(term_to_binary(term))
  end

  defp term_to_binary(map) when is_map(map) do
    ^map = Map.from_struct(map)

    map
    |> Map.to_list()
    |> Enum.map(fn {key, value} -> {key, term_to_binary(value)} end)
    |> Enum.into(%{})
  end

  defp term_to_binary(list) when is_list(list) do
    Enum.map(list, &term_to_binary(&1))
  end

  defp term_to_binary(tuple) when is_tuple(tuple) do
    Tuple.to_list(tuple)
    |> Enum.map(&term_to_binary(&1))
    |> List.to_tuple()
  end

  defp term_to_binary(other) do
    other
  end

  @spec decode!(binary()) :: any()
  def decode!(term) do
    :erlang.binary_to_term(term, [:safe])
  end
end

defmodule ZBert do
  require Record
  Record.defrecord(:zbert, in_stream: nil, out_stream: nil, module: nil)

  def init(mod) do
    out = :zlib.open()
    :ok = :zlib.deflateInit(out)

    inc = :zlib.open()
    :ok = :zlib.inflateInit(inc)

    zbert(in_stream: inc, out_stream: out, module: mod)
  end

  def encode!(zbert(out_stream: str, module: mod), term) do
    data = mod.encode!(term)
    :zlib.deflate(str, data, :sync)
  end

  def decode!(zbert(in_stream: str, module: mod), data) do
    :zlib.inflate(str, data)
    |> mod.decode!()
  end
end

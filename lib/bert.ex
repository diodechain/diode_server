# Diode Server
# Copyright 2021-2024 Diode
# Licensed under the Diode License, Version 1.1
defmodule BertInt do
  @moduledoc """
  Binary Erlang Term encoding for internal node-to-node encoding.
  """
  @spec encode!(any()) :: binary()
  def encode!(term, level \\ 7) do
    term
    |> :erlang.term_to_binary()
    |> zip(level)
  end

  def encode_zstd!(term, level \\ 11) do
    term
    |> :erlang.term_to_binary()
    |> :ezstd.compress(level)
  end

  def zip(data, level) do
    z = :zlib.open()
    :ok = :zlib.deflateInit(z, level, :deflated, -15, 9, :default)
    b = :zlib.deflate(z, data, :finish)
    :zlib.deflateEnd(z)
    :zlib.close(z)
    :erlang.iolist_to_binary(b)
  end

  # Custom impl of :zlib.zip() for faster compression
  @spec decode!(binary()) :: any()
  def decode!(<<40, 181, 47, 253, _::binary>> = zstd_term) do
    :ezstd.decompress(zstd_term)
    |> :erlang.binary_to_term()
  end

  def decode!(term) do
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
    :erlang.term_to_binary(term_to_binary(term), minor_version: 1)
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

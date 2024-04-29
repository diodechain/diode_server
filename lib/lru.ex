# Diode Server
# Copyright 2021-2024 Diode
# Licensed under the Diode License, Version 1.1
defmodule Lru do
  @moduledoc """
  Provides Least-Recently-Used Queue with a fixed maximum size
  """
  defstruct queue: :queue.new(), map: %{}, max_size: nil
  @type t :: %Lru{queue: any(), map: map(), max_size: integer()}

  @spec new(pos_integer()) :: Lru.t()
  def new(max_size) do
    %Lru{max_size: max_size}
  end

  @spec insert(Lru.t(), any(), any()) :: Lru.t()
  def insert(lru, key, value) do
    lru = %{lru | queue: :queue.in(key, lru.queue)}

    lru = %{
      lru
      | map:
          Map.update(lru.map, key, {0, value}, fn {count, _} ->
            {count + 1, value}
          end)
    }

    if map_size(lru.map) > lru.max_size do
      shrink(lru)
    else
      lru
    end
  end

  @spec get(Lru.t(), any(), any()) :: any()
  def get(lru, key, default \\ nil) do
    case Map.get(lru.map, key) do
      {_, value} -> value
      _ -> default
    end
  end

  @spec fetch(Lru.t(), any(), fun()) :: {Lru.t(), any()}
  def fetch(lru, key, filler) do
    case Map.get(lru.map, key) do
      {_, value} ->
        {lru, value}

      _ ->
        case filler.() do
          nil -> {lru, nil}
          value -> {insert(lru, key, value), value}
        end
    end
  end

  @spec size(Lru.t()) :: non_neg_integer()
  def size(lru) do
    map_size(lru.map)
  end

  defp shrink(lru) do
    {{:value, key}, queue} = :queue.out(lru.queue)
    lru = %{lru | queue: queue}

    case Map.get(lru.map, key) do
      {0, _} ->
        %{lru | map: Map.delete(lru.map, key)}

      {counter, value} ->
        shrink(%{lru | map: Map.put(lru.map, key, {counter - 1, value})})
    end
  end
end

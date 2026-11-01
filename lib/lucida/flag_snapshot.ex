defmodule Lucida.FlagSnapshot do
  @moduledoc """
  Flags evaluated once for one distinct id (`Lucida.Client.evaluate_flags/3`). Reads never touch the
  network or emit exposure events. Immutable: `get_flag/2` returns the value and the updated snapshot,
  which remembers which keys were read so `only_accessed/1` can attach just those to an event.
  """

  defstruct values: %{}, payloads: %{}, accessed: MapSet.new()

  @doc "`$feature/<key>` per flag plus sorted `$active_feature_flags`; caller properties win."
  def event_props(props, values) when map_size(values) == 0, do: props || %{}

  def event_props(props, values) do
    flags = Map.new(values, fn {k, v} -> {"$feature/#{k}", v} end)
    active = values |> Enum.reject(fn {_, v} -> v == false end) |> Enum.map(&elem(&1, 0)) |> Enum.sort()

    flags
    |> Map.put("$active_feature_flags", active)
    |> Map.merge(props || %{})
  end

  def new(values, payloads \\ %{}), do: %__MODULE__{values: values, payloads: payloads}

  @doc "{value | nil, snapshot}"
  def get_flag(%__MODULE__{} = s, key),
    do: {Map.get(s.values, key), %{s | accessed: MapSet.put(s.accessed, key)}}

  @doc "{boolean, snapshot}"
  def enabled?(%__MODULE__{} = s, key) do
    {v, s} = get_flag(s, key)
    {v != nil and v != false, s}
  end

  def get_payload(%__MODULE__{} = s, key), do: Map.get(s.payloads, key)

  def keys(%__MODULE__{} = s), do: s.values |> Map.keys() |> Enum.sort()

  def only(%__MODULE__{} = s, keys),
    do: %__MODULE__{values: Map.take(s.values, keys), payloads: Map.take(s.payloads, keys)}

  def only_accessed(%__MODULE__{} = s), do: only(s, MapSet.to_list(s.accessed))

  def props_for(%__MODULE__{} = s, props \\ %{}), do: event_props(props, s.values)
end

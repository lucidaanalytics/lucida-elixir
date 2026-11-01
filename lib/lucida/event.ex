defmodule Lucida.Event do
  @moduledoc "Builds wire events (uuid v7 per event so the server can dedupe retries)."

  @version "0.1.0"
  @lib "lucida-elixir"

  def version, do: @version

  @doc "opts: :uuid, :timestamp (string or DateTime), :groups, :set, :set_once."
  def build(distinct_id, event, properties, opts \\ []) do
    props = Map.merge(properties || %{}, %{"$lib" => @lib, "$lib_version" => @version})

    %{
      "uuid" => opts[:uuid] || uuid7(),
      "event" => event,
      "distinct_id" => distinct_id,
      "timestamp" => iso(opts[:timestamp]),
      "properties" => props
    }
    |> put_nonempty("$set", opts[:set])
    |> put_nonempty("$set_once", opts[:set_once])
    |> put_nonempty("$groups", opts[:groups])
  end

  def iso(nil), do: iso(DateTime.utc_now())
  def iso(t) when is_binary(t), do: t

  def iso(%DateTime{} = t),
    do: t |> DateTime.shift_zone!("Etc/UTC") |> DateTime.truncate(:millisecond) |> DateTime.to_iso8601()

  def uuid7 do
    <<a::12, b::62, _::6>> = :crypto.strong_rand_bytes(10)
    hex = Base.encode16(<<System.os_time(:millisecond)::48, 7::4, a::12, 2::2, b::62>>, case: :lower)
    <<p1::binary-8, p2::binary-4, p3::binary-4, p4::binary-4, p5::binary-12>> = hex
    Enum.join([p1, p2, p3, p4, p5], "-")
  end

  defp put_nonempty(m, _k, nil), do: m
  defp put_nonempty(m, _k, v) when v == %{}, do: m
  defp put_nonempty(m, k, v), do: Map.put(m, k, v)
end

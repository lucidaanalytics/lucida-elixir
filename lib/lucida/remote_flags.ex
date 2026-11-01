defmodule Lucida.RemoteFlags do
  @moduledoc "Server calls for flags: the `POST /v1/flags` fallback for flags undecidable locally, and remote-config payloads."

  @doc "Value (`true`, `false` or a variant key) of `key`, or `nil` on any failure."
  def fetch(cfg, key, distinct_id, opts) do
    body = JSON.encode!(request_body(cfg, key, distinct_id, opts))

    with {:ok, %{status: st, body: resp}} when st in 200..299 <-
           cfg.http.request(:post, cfg.host <> "/v1/flags", [{"content-type", "application/json"}], body),
         {:ok, %{"flags" => %{^key => flag}}} <- JSON.decode(resp) do
      value(flag)
    else
      _ -> nil
    end
  rescue
    _ -> nil
  end

  @doc "The `POST /v1/flags` body; `:anon_distinct_id` links the pre-identify id so flags keep their bucket."
  def request_body(cfg, key, distinct_id, opts) do
    base = %{
      "api_key" => cfg.api_key,
      "distinct_id" => distinct_id,
      "groups" => opts[:groups] || %{},
      "person_properties" => opts[:person_properties] || %{},
      "group_properties" => opts[:group_properties] || %{},
      "flag_keys" => [key]
    }

    if opts[:anon_distinct_id], do: Map.put(base, "anon_distinct_id", opts[:anon_distinct_id]), else: base
  end

  @doc "Payload of remote-config flag `key` (`GET /v1/flags/{key}/remote-config`, secret key); `nil` on 404 or any failure."
  def remote_config(cfg, key) do
    url = cfg.host <> "/v1/flags/" <> URI.encode(key, &URI.char_unreserved?/1) <> "/remote-config"

    with {:ok, %{status: st, body: resp}} when st in 200..299 <-
           cfg.http.request(:get, url, [{"authorization", "Bearer #{cfg.secret}"}], nil),
         {:ok, %{"payload" => p}} <- JSON.decode(resp) do
      p
    else
      _ -> nil
    end
  rescue
    _ -> nil
  end

  defp value(%{"value" => v}) when is_boolean(v) or is_binary(v), do: v
  defp value(%{"variant" => v}) when is_binary(v) and v != "", do: v
  defp value(%{"enabled" => e}) when is_boolean(e), do: e
  defp value(_), do: false
end

defmodule Lucida.Context do
  @moduledoc """
  Request context for server-side events: distinct id, session id and request properties
  (`$current_url`, `$ip`, ...). Pure functions plus a process-local slot, so it works the same
  from a Plug pipeline (`Lucida.Plug`), a Phoenix LiveView `mount/3` or any other process.

  The tracing headers and the cookie are client-controlled: use them to join events to a browser
  session, never for authentication.
  """

  @distinct_header "x-lucida-distinct-id"
  @session_header "x-lucida-session-id"
  @key :lucida_context

  @type t :: %{distinct_id: String.t() | nil, session_id: String.t() | nil, properties: map()}

  @doc """
  Builds a context from `%{headers: [{name, value}], cookies: %{name => value}, url: binary,
  method: binary, remote_ip: tuple | binary}` (every key optional; header names any case).

  Options: `:cookie` (cookie holding the browser distinct id, default `"lc_distinct_id"`),
  `:trust_proxy` (take `$ip` from the first `x-forwarded-for` hop), `:disable_geoip` (omit `$ip`
  and mark events `$geoip_disable`).
  """
  @spec from_request(map(), keyword()) :: t()
  def from_request(req, opts \\ []) do
    headers = Map.new(req[:headers] || [], fn {k, v} -> {String.downcase(to_string(k)), v} end)
    cookies = req[:cookies] || %{}
    distinct = clean(headers[@distinct_header]) || clean(cookies[opts[:cookie] || "lc_distinct_id"])
    session = clean(headers[@session_header])

    props =
      %{}
      |> put("$current_url", clean(req[:url]))
      |> put("$request_method", req[:method] && clean(String.upcase(to_string(req[:method]))))
      |> put("$user_agent", clean(headers["user-agent"]))
      |> put("$session_id", session)
      |> put_ip(headers, req[:remote_ip], %{disable_geoip: opts[:disable_geoip] == true, trust_proxy: opts[:trust_proxy] == true})

    %{distinct_id: distinct, session_id: session, properties: props}
  end

  defp put_ip(props, _headers, _ip, %{disable_geoip: true}), do: Map.put(props, "$geoip_disable", true)

  defp put_ip(props, headers, remote_ip, opts) do
    fwd = if opts.trust_proxy, do: headers["x-forwarded-for"] |> to_string() |> String.split(",") |> hd() |> clean()
    put(props, "$ip", fwd || clean(format_ip(remote_ip)))
  end

  defp format_ip(nil), do: nil
  defp format_ip(ip) when is_binary(ip), do: ip
  defp format_ip(ip) when is_tuple(ip), do: ip |> :inet.ntoa() |> to_string()

  defp put(m, _k, nil), do: m
  defp put(m, k, v), do: Map.put(m, k, v)

  @doc "Strips control characters, trims, caps at 1000 characters; empty becomes `nil`."
  def clean(nil), do: nil

  def clean(v) do
    s = v |> to_string() |> String.replace(~r/[\x00-\x1f\x7f]/u, "") |> String.trim() |> String.slice(0, 1000)
    if s == "", do: nil, else: s
  end

  # -- process-local slot ------------------------------------------------------------------------

  @doc "Makes `ctx` the ambient context of the calling process (a LiveView process calls this in `mount/3`)."
  def put(ctx) do
    Process.put(@key, ctx)
    :ok
  end

  @doc "The ambient context of the calling process, or `nil`."
  def current, do: Process.get(@key)

  @doc "Runs `fun` with `ctx` ambient, restoring the previous context afterwards."
  def with_context(ctx, fun) do
    prev = Process.put(@key, ctx)

    try do
      fun.()
    after
      if prev, do: Process.put(@key, prev), else: Process.delete(@key)
    end
  end

  @doc """
  Session-safe form of a context (two strings), to carry it from a controller/plug into a LiveView
  through the Phoenix session: `put_session(conn, Lucida.Context.to_session(ctx))` and, in `mount/3`,
  `Lucida.Context.put(Lucida.Context.from_session(session))`.
  """
  def to_session(%{distinct_id: d, session_id: s}),
    do: Enum.reject(%{"lucida_distinct_id" => d, "lucida_session_id" => s}, fn {_, v} -> is_nil(v) end) |> Map.new()

  def from_session(session) when is_map(session) do
    %{
      distinct_id: clean(session["lucida_distinct_id"]),
      session_id: clean(session["lucida_session_id"]),
      properties: if(s = clean(session["lucida_session_id"]), do: %{"$session_id" => s}, else: %{})
    }
  end
end

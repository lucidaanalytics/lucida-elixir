if Code.ensure_loaded?(Plug.Conn) do
  defmodule Lucida.Plug do
    @moduledoc """
    Phoenix/Plug integration (compiled only when `:plug` is a dependency of your app).

    Builds a `Lucida.Context` from the request (distinct id from the `X-Lucida-Distinct-Id`
    header or the `:cookie`, `$current_url`, `$ip`), makes it the ambient context of the request
    process and stores it in `conn.assigns.lucida`:

        plug Lucida.Plug, client: MyApp.Lucida, disable_geoip: false

    Options: `:cookie`, `:trust_proxy`, `:disable_geoip` (see `Lucida.Context.from_request/2`).
    Then `Lucida.Client.capture_in_context(MyApp.Lucida, "signup")` anywhere in the request.
    For LiveView, put `Lucida.Context.to_session(conn.assigns.lucida)` into the session and call
    `Lucida.Context.put(Lucida.Context.from_session(session))` in `mount/3`.
    """
    @behaviour Plug

    @impl true
    def init(opts), do: opts

    @impl true
    def call(conn, opts) do
      conn = Plug.Conn.fetch_cookies(conn)

      ctx =
        Lucida.Context.from_request(
          %{
            headers: conn.req_headers,
            cookies: conn.req_cookies,
            url: Plug.Conn.request_url(conn),
            method: conn.method,
            remote_ip: conn.remote_ip
          },
          opts
        )

      Lucida.Context.put(ctx)
      Plug.Conn.assign(conn, :lucida, ctx)
    end
  end
end

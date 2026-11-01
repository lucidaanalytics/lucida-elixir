defmodule Lucida.Http.Httpc do
  @moduledoc "`Lucida.Http` adapter on OTP `:httpc` with TLS peer verification."
  @behaviour Lucida.Http

  @impl true
  def request(method, url, headers, body) do
    {:ok, _} = Application.ensure_all_started(:inets)
    {:ok, _} = Application.ensure_all_started(:ssl)

    h = for {k, v} <- headers, do: {String.to_charlist(k), String.to_charlist(v)}
    u = String.to_charlist(url)
    req = if method == :post, do: {u, h, ~c"application/json", body}, else: {u, h}

    opts = [
      timeout: 10_000,
      connect_timeout: 5_000,
      ssl: [
        verify: :verify_peer,
        cacerts: :public_key.cacerts_get(),
        customize_hostname_check: [match_fun: :public_key.pkix_verify_hostname_match_fun(:https)]
      ]
    ]

    case :httpc.request(method, req, opts, body_format: :binary) do
      {:ok, {{_, status, _}, rh, rb}} ->
        headers = for {k, v} <- rh, do: {k |> List.to_string() |> String.downcase(), List.to_string(v)}
        {:ok, %{status: status, body: rb, headers: headers}}

      {:error, reason} ->
        {:error, reason}
    end
  end
end

defmodule Lucida.FakeHttp do
  @moduledoc "Test adapter for `Lucida.Http`: records requests, replays scripted responses (default 200)."
  @behaviour Lucida.Http

  def start_link, do: Agent.start_link(fn -> %{reqs: [], responses: []} end, name: __MODULE__)

  def status(code), do: {:ok, %{status: code, body: "{}", headers: []}}

  def respond(responses), do: Agent.update(__MODULE__, &%{&1 | responses: responses})

  def requests, do: Agent.get(__MODULE__, &Enum.reverse(&1.reqs))

  @doc "Events of every POST /v1/batch so far, in order."
  def events do
    for %{method: :post, url: url, body: body} <- requests(),
        e <- JSON.decode!(if(String.contains?(url, "compression=gzip"), do: :zlib.gunzip(body), else: body))["batch"],
        do: e
  end

  @impl true
  def request(method, url, headers, body) do
    Agent.get_and_update(__MODULE__, fn st ->
      {resp, rest} =
        case st.responses do
          [r | t] -> {r, t}
          [] -> {status(200), []}
        end

      req = %{method: method, url: url, headers: headers, body: body}
      {resp, %{st | reqs: [req | st.reqs], responses: rest}}
    end)
  end
end

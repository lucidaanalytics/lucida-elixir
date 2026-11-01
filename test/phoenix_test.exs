defmodule Lucida.PhoenixTest do
  use ExUnit.Case, async: false

  alias Lucida.{Client, Context, FakeHttp}

  setup do
    start_supervised!(%{id: FakeHttp, start: {FakeHttp, :start_link, []}})
    :ok
  end

  defp client(extra \\ []) do
    start_supervised!({Client, [api_key: "lc_pk_x", http: FakeHttp, flush_interval_ms: 3_600_000] ++ extra})
  end

  describe "Context.from_request/2" do
    test "distinct id from header, then cookie; url and ip" do
      req = %{
        headers: [{"X-Lucida-Distinct-Id", "hdr-user"}, {"user-agent", "ua"}],
        cookies: %{"lc_distinct_id" => "cookie-user"},
        url: "https://app.test/p?x=1",
        method: "get",
        remote_ip: {10, 0, 0, 7}
      }

      ctx = Context.from_request(req)
      assert ctx.distinct_id == "hdr-user"
      assert ctx.properties["$current_url"] == "https://app.test/p?x=1"
      assert ctx.properties["$ip"] == "10.0.0.7"
      assert ctx.properties["$request_method"] == "GET"

      assert Context.from_request(%{req | headers: []}).distinct_id == "cookie-user"
      assert Context.from_request(%{req | headers: []}, cookie: "other").distinct_id == nil
    end

    test "trust_proxy uses x-forwarded-for; disable_geoip drops $ip and marks the event" do
      req = %{headers: [{"x-forwarded-for", "1.2.3.4, 5.6.7.8"}], remote_ip: {10, 0, 0, 7}}
      assert Context.from_request(req, trust_proxy: true).properties["$ip"] == "1.2.3.4"
      geo = Context.from_request(req, disable_geoip: true).properties
      refute Map.has_key?(geo, "$ip")
      assert geo["$geoip_disable"] == true
    end

    test "control characters are stripped from client-controlled ids" do
      ctx = Context.from_request(%{headers: [{"x-lucida-distinct-id", " a\u0000b "}]})
      assert ctx.distinct_id == "ab"
    end
  end

  test "ambient context feeds capture_in_context and survives a session round trip" do
    lc = client()
    ctx = Context.from_request(%{headers: [{"x-lucida-distinct-id", "u1"}], url: "https://app.test/"})
    assert Client.capture_in_context(lc, "early") == {:error, :no_distinct_id}

    Context.with_context(ctx, fn -> Client.capture_in_context(lc, "signup", %{"plan" => "pro"}) end)
    assert Context.current() == nil

    Context.put(Context.from_session(Context.to_session(ctx)))
    Client.capture_in_context(lc, "from_live_view")
    assert Client.flush(lc) == :ok

    [a, b] = FakeHttp.events()
    assert a["distinct_id"] == "u1" and a["properties"]["plan"] == "pro" and a["properties"]["$current_url"] == "https://app.test/"
    assert b["distinct_id"] == "u1"
  end

  test "identify and group_identify dedupe; person property setters" do
    lc = client()
    for _ <- 1..3 do
      Client.identify(lc, "u", %{"a" => 1})
      Client.group_identify(lc, "org", "acme", %{"n" => 1})
    end

    Client.identify(lc, "u", %{"a" => 2})
    Client.set_person_properties(lc, "u", %{"plan" => "pro"})
    Client.set_person_properties_once(lc, "u", %{"first" => "x"})
    assert Client.flush(lc) == :ok

    evs = FakeHttp.events()
    assert Enum.map(evs, & &1["event"]) == ["$identify", "$groupidentify", "$identify", "$set", "$set"]
    assert Enum.at(evs, 3)["$set"] == %{"plan" => "pro"}
    assert Enum.at(evs, 4)["$set_once"] == %{"first" => "x"}
  end

  test "undecidable flags fall back to the server unless only_evaluate_locally; :default applies" do
    undecided = [%{"key" => "k", "type" => "boolean", "active" => true, "salt" => "s", "aggregation" => %{"kind" => "person"},
                   "conditions" => [%{"rollout_pct" => 100, "filters" => [%{"type" => "cohort", "key" => "c1", "op" => "in", "value" => 1}]}]}]

    FakeHttp.respond([FakeHttp.status(200)])
    local = client(only_evaluate_locally: true)
    Client.set_definitions(local, undecided)
    assert Client.get_feature_flag(local, "k", "u", default: :fallback) == :fallback
    assert Enum.empty?(for %{url: u} <- FakeHttp.requests(), String.ends_with?(u, "/v1/flags"), do: u)

    FakeHttp.respond([{:ok, %{status: 200, body: ~s({"flags":{"k":{"value":"b"}}}), headers: []}}])
    remote = start_supervised!({Client, [api_key: "lc_pk_x", http: FakeHttp, flush_interval_ms: 3_600_000, only_evaluate_locally: false]}, id: :remote)
    Client.set_definitions(remote, undecided)
    assert Client.get_feature_flag(remote, "k", "u") == "b"
  end
end

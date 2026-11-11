defmodule Lucida.ClientTest do
  use ExUnit.Case, async: false

  alias Lucida.{Client, FakeHttp}

  @data System.get_env("LUCIDA_TESTDATA") || Path.expand("../../../testdata", __DIR__)

  setup do
    start_supervised!(%{id: FakeHttp, start: {FakeHttp, :start_link, []}})
    :ok
  end

  defp client(extra \\ []) do
    opts = [api_key: "lc_pk_x", http: FakeHttp, flush_interval_ms: 3_600_000] ++ extra
    start_supervised!({Client, opts})
  end

  test "event wire fixtures" do
    cases = [@data, "events/server_sdk.json"] |> Path.join() |> File.read!() |> JSON.decode!() |> Map.fetch!("cases")

    Enum.each(cases, &run_fixture/1)
  end

  defp run_fixture(c) do
    FakeHttp.respond([])
    before = length(FakeHttp.events())
    {:ok, lc} = Client.start_link(api_key: "lc_pk_x", http: FakeHttp, flush_interval_ms: 3_600_000)
    call = c["call"]

    case call["method"] do
      "capture" ->
        Client.capture(lc, call["distinct_id"], call["event"], call["properties"],
          groups: call["groups"], timestamp: call["timestamp"], uuid: call["uuid"], set: call["set"], set_once: call["set_once"])

      "identify" -> Client.identify(lc, call["distinct_id"], call["properties"], call["properties_set_once"])
      "alias" -> Client.create_alias(lc, call["distinct_id"], call["alias"])
      _ -> Client.group_identify(lc, call["group_type"], call["group_key"], call["properties"], call["distinct_id"])
    end

    assert Client.flush(lc) == :ok
    [ev] = Enum.drop(FakeHttp.events(), before)
    GenServer.stop(lc)

    {lib, props} = Map.pop(ev["properties"], "$lib")
    assert String.starts_with?(lib, "lucida-"), c["name"]
    {ver, props} = Map.pop(props, "$lib_version")
    assert ver, c["name"]
    ev = %{ev | "properties" => props}

    want =
      Enum.reduce(["uuid", "timestamp"], c["expected"], fn k, w ->
        if w[k] == "*" and ev[k] not in [nil, ""], do: Map.put(w, k, ev[k]), else: w
      end)

    assert ev == want, c["name"]
  end

  test "batches at flush_at and bounds the queue" do
    lc = client(flush_at: 3, max_queue_size: 5)
    for i <- 0..6, do: Client.capture(lc, "u", "e#{i}")
    assert Client.flush(lc) == :ok
    assert length(FakeHttp.events()) == 7
    sizes = for %{body: b} <- FakeHttp.requests(), do: length(JSON.decode!(b)["batch"])
    assert sizes == [3, 3, 1]
  end

  test "a failed batch is kept and re-sent with the same uuid" do
    lc = client()
    FakeHttp.respond([FakeHttp.status(503)])
    Client.capture(lc, "u", "e")
    assert Client.flush(lc) == :error
    assert Client.flush(lc) == :ok
    [a, b] = FakeHttp.events()
    assert a["uuid"] == b["uuid"]
  end

  test "non-retryable 4xx drops the batch" do
    lc = client()
    FakeHttp.respond([FakeHttp.status(400)])
    Client.capture(lc, "u", "e")
    assert Client.flush(lc) == :ok
    assert Client.dropped(lc) == 1
    assert Client.flush(lc) == :ok
    assert length(FakeHttp.requests()) == 1
  end

  test "local flags emit one exposure pair per user, flag and value" do
    lc = client()
    defs = [@data, "flags/vectors_basic.json"] |> Path.join() |> File.read!() |> JSON.decode!() |> Map.fetch!("flags")
    Client.set_definitions(lc, defs)
    key = hd(defs)["key"]
    Client.get_feature_flag(lc, key, "user-1")
    Client.get_feature_flag(lc, key, "user-1")
    Client.flush(lc)
    assert Enum.count(FakeHttp.events(), &(&1["event"] in ["$feature_flag_called", "$exposure"])) == 2
  end

  test "disabled sends nothing and evaluates nothing" do
    lc = client(disabled: true)
    Client.capture(lc, "u", "e")
    assert Client.flush(lc) == :ok
    assert FakeHttp.requests() == []
    assert Client.get_feature_flag(lc, "x", "u") == nil
  end

  test "reload fetches definitions with the secret key and honours the ETag" do
    flag = %{"key" => "on", "type" => "boolean", "active" => true, "salt" => "s", "aggregation" => %{"kind" => "person"}, "conditions" => [%{"rollout_pct" => 100}]}
    body = JSON.encode!(%{"flags" => [flag]})
    FakeHttp.respond([{:ok, %{status: 200, body: body, headers: [{"etag", "\"v1\""}]}}, FakeHttp.status(304)])
    lc = client(secret_key: "lc_sk_x")
    assert Client.get_feature_flag(lc, "on", "u1", send_exposure: false) == true
    assert Client.reload_feature_flags(lc)
    [first, second] = Enum.filter(FakeHttp.requests(), &(&1.method == :get))
    assert {"authorization", "Bearer lc_sk_x"} in first.headers
    assert {"if-none-match", "\"v1\""} in second.headers
  end

  test "remote config payload GETs the escaped route with the secret key" do
    rc = JSON.encode!(%{"key" => "a/b", "enabled" => true, "payload" => %{"x" => 1}})
    FakeHttp.respond([FakeHttp.status(200), {:ok, %{status: 200, body: rc, headers: []}}, FakeHttp.status(404)])
    lc = client(secret_key: "lc_sk_x")
    assert Client.get_remote_config_payload(lc, "a/b") == %{"x" => 1}
    assert Client.get_remote_config_payload(lc, "nope") == nil
    req = Enum.find(FakeHttp.requests(), &String.ends_with?(&1.url, "/v1/flags/a%2Fb/remote-config"))
    assert req.method == :get and {"authorization", "Bearer lc_sk_x"} in req.headers
    {:ok, no_secret} = Client.start_link(api_key: "lc_pk_x", http: FakeHttp, flush_interval_ms: 3_600_000)
    assert_raise ArgumentError, fn -> Client.get_remote_config_payload(no_secret, "a/b") end
  end

  test "fallbacks serve the value with reason fallback and no exposure" do
    flag = %{"key" => "on", "type" => "boolean", "active" => true, "salt" => "s", "aggregation" => %{"kind" => "person"}, "conditions" => [%{"rollout_pct" => 100}]}
    lc = client(fallbacks: %{"ghost" => "safe"})
    Client.set_definitions(lc, [flag])
    d = Client.get_feature_flag_details(lc, "ghost", "u")
    assert d.value == "safe" and d.reason == "fallback"
    assert Client.get_feature_flag(lc, "ghost", "u", default: "d") == "safe"
    on = Client.get_feature_flag_details(lc, "on", "u", send_exposure: false)
    assert on.value == true and on.reason == "condition_match" and on.condition_index == 0
    assert Client.get_feature_flag_details(lc, "nope", "u") == nil
    assert Client.get_feature_flag(lc, "nope", "u", default: "d") == "d"
    Client.flush(lc)
    assert FakeHttp.events() == []
  end

  test "network failure serves the fallback" do
    FakeHttp.respond([FakeHttp.status(503)])
    lc = client(only_evaluate_locally: false, fallbacks: %{"x" => "down"})
    assert Client.get_feature_flag_details(lc, "x", "u").reason == "fallback"
  end

  test "identify and group_identify are resent after their batch was dropped" do
    FakeHttp.respond([FakeHttp.status(400)])
    lc = client()

    for _ <- 1..2 do
      Client.identify(lc, "u", %{"a" => 1})
      Client.group_identify(lc, "org", "acme", %{"n" => 1})
      Client.flush(lc)
    end

    assert Enum.map(FakeHttp.events(), & &1["event"]) == ["$identify", "$groupidentify", "$identify", "$groupidentify"]
  end
end

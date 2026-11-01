defmodule Lucida.FlagSnapshotTest do
  use ExUnit.Case, async: false

  alias Lucida.{Client, FakeHttp, FlagSnapshot}

  setup do
    start_supervised!(%{id: FakeHttp, start: {FakeHttp, :start_link, []}})
    :ok
  end

  defp on(key, ctxs \\ [], pct \\ 100) do
    %{
      "key" => key, "type" => "boolean", "active" => true, "salt" => "s", "aggregation" => %{"kind" => "person"},
      "app_contexts" => ctxs, "conditions" => [%{"rollout_pct" => pct}]
    }
  end

  defp client do
    lc = start_supervised!({Client, api_key: "lc_pk_x", http: FakeHttp, flush_interval_ms: 3_600_000, app_contexts: ["api"]})
    Client.set_definitions(lc, [on("a"), on("b"), on("off", [], 0), on("web", ["web"])])
    lc
  end

  test "snapshot drops app-context-excluded flags and reads without exposure events" do
    lc = client()
    snap = Client.evaluate_flags(lc, "u")
    assert FlagSnapshot.keys(snap) == ["a", "b", "off"]
    {enabled, snap} = FlagSnapshot.enabled?(snap, "a")
    assert enabled
    assert FlagSnapshot.only_accessed(snap).values == %{"a" => true}

    Client.capture(lc, "u", "e1", %{}, flags: FlagSnapshot.only_accessed(snap))
    assert :ok = Client.flush(lc)
    names = FakeHttp.events() |> Enum.map(& &1["event"])
    assert names == ["e1"]
  end

  test "send_feature_flags enriches events; caller properties win" do
    lc = client()
    Client.capture(lc, "u", "buy", %{"$feature/a" => "mine"}, send_feature_flags: true)
    assert :ok = Client.flush(lc)
    [ev] = FakeHttp.events()
    p = ev["properties"]
    assert p["$feature/a"] == "mine"
    assert p["$feature/off"] == false
    refute Map.has_key?(p, "$feature/web")
    assert p["$active_feature_flags"] == ["a", "b"]
  end

  test "event_props with no values leaves properties alone" do
    assert FlagSnapshot.event_props(%{"x" => 1}, %{}) == %{"x" => 1}
    assert FlagSnapshot.event_props(%{"$active_feature_flags" => []}, %{"a" => "v"})["$active_feature_flags"] == []
  end
end

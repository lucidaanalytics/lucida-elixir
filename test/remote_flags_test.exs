defmodule Lucida.RemoteFlagsTest do
  use ExUnit.Case, async: true

  alias Lucida.RemoteFlags

  test "request body carries anon_distinct_id only when given" do
    cfg = %{api_key: "lc_pk"}
    with_anon = RemoteFlags.request_body(cfg, "k", "u1", anon_distinct_id: "anon-9")
    assert with_anon["anon_distinct_id"] == "anon-9"
    assert with_anon["distinct_id"] == "u1" and with_anon["flag_keys"] == ["k"]
    refute Map.has_key?(RemoteFlags.request_body(cfg, "k", "u1", []), "anon_distinct_id")
  end
end

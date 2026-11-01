defmodule Lucida.ConformanceTest do
  use ExUnit.Case, async: true

  alias Lucida.Evaluator

  @flags_dir (if d = System.get_env("LUCIDA_TESTDATA"), do: Path.join(d, "flags"), else: Path.expand("../../../testdata/flags", __DIR__))

  # Context fields each `needs` entry lets the evaluator see (an SDK without the rest must not use it).
  @ctx_fields %{
    "distinct_id" => ["distinct_id", "bucketing_key"],
    "groups" => ["groups"],
    "person_properties" => ["person_properties"],
    "group_properties" => ["group_properties"],
    "device_properties" => ["device_properties"],
    "geo_properties" => ["geo_properties"],
    "app_version" => ["app_version"]
  }

  defp supplied(%{"needs" => needs, "context" => ctx}) do
    keep = Enum.flat_map(needs, &Map.get(@ctx_fields, &1, []))
    Map.take(ctx, keep)
  end

  defp supplied(%{"context" => ctx}), do: ctx

  defp check(file) do
    d = [@flags_dir, file] |> Path.join() |> File.read!() |> JSON.decode!()

    for h <- d["hash_vectors"], do: assert(Evaluator.hash01(h["input"]) == h["hash"], h["input"])

    for v <- d["vectors"] do
      r = Evaluator.evaluate_all(d["flags"], supplied(v))[v["flag"]]
      e = v["expected"]

      assert {r.value, r.variant, r.payload, r.reason, r.condition_index} ==
               {e["value"], e["variant"], e["payload"], e["reason"], e["condition_index"]},
             v["name"]
    end

    length(d["vectors"])
  end

  test "basic", do: assert(check("vectors_basic.json") > 20)
  test "g10 device, namespace, holdout", do: assert(check("vectors_g10.json") > 15)
  test "sticky", do: assert(check("vectors_sticky.json") >= 19)
  test "spec v2 operators, early exit, per-condition unit", do: assert(check("vectors_ops.json") >= 100)
  test "generated", do: assert(check("vectors.json") == 10_000)
end

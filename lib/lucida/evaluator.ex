defmodule Lucida.Evaluator do
  @moduledoc """
  Local flag evaluator; behaviour pinned by the shared `testdata/flags` vectors
  (see `testdata/flags/README.md`). Flags and contexts are string-keyed maps exactly as
  decoded from JSON. Supports person/group/device aggregation, namespace, holdout and sticky
  bucketing; multi-kind contexts (`vectors_g18.json`) are not supported by this SDK.
  """

  @requires_server "requires_server"
  @unit 4_503_599_627_370_496.0

  def requires_server, do: @requires_server

  @doc "sha256(text)[0..13) as a fraction of 16^13."
  def hash01(text) do
    hex = :crypto.hash(:sha256, text) |> Base.encode16(case: :lower)
    String.to_integer(binary_part(hex, 0, 13), 16) / @unit
  end

  defp off(reason, idx \\ -1),
    do: %{value: false, reason: reason, condition_index: idx, variant: nil, payload: nil}

  # -- operators ------------------------------------------------------------------------------

  defp equal?(a, b) when is_number(a) or is_number(b), do: is_number(a) and is_number(b) and a == b
  defp equal?(a, b), do: a == b

  defp to_float(v) when is_number(v), do: v / 1

  defp to_float(v) when is_binary(v) do
    s = String.trim(v)
    s = if String.starts_with?(s, "."), do: "0" <> s, else: s

    case Float.parse(s) do
      {f, ""} -> f
      _ -> nil
    end
  end

  defp to_float(_), do: nil

  defp semver(v) when is_binary(v) do
    s = v |> String.trim() |> String.replace_prefix("v", "") |> String.split(~r/[-+]/, parts: 2) |> hd()
    parts = String.split(s, ".")

    if Enum.all?(parts, &Regex.match?(~r/\A[0-9]+\z/, &1)),
      do: Enum.map(parts, &String.to_integer/1),
      else: nil
  end

  defp semver(_), do: nil

  defp cmp_semver(a, b) do
    with pa when pa != nil <- semver(a), pb when pb != nil <- semver(b) do
      n = max(length(pa), length(pb))
      compare(pad(pa, n), pad(pb, n))
    end
  end

  defp pad(l, n), do: l ++ List.duplicate(0, n - length(l))

  defp compare(a, b) when a < b, do: -1
  defp compare(a, b) when a > b, do: 1
  defp compare(_, _), do: 0

  defp cmp_num(a, b) do
    with x when x != nil <- to_float(a), y when y != nil <- to_float(b), do: compare(x, y)
  end

  defp regex(pattern, s) do
    case Regex.compile(pattern) do
      {:ok, re} -> Regex.match?(re, s)
      _ -> nil
    end
  end

  def op_match?(op, prop, present, want, semver, now \\ nil) do
    set = present and prop != nil

    case op do
      "is_set" -> set
      "is_not_set" -> not set
      _ when not set -> false
      _ -> apply_op(op, prop, want, semver, now)
    end
  end

  defp apply_op(op, prop, want, semver, _) when op in ["eq", "neq"] do
    if semver do
      case cmp_semver(prop, want) do
        nil -> false
        c -> (c == 0) == (op == "eq")
      end
    else
      equal?(prop, want) == (op == "eq")
    end
  end

  defp apply_op(op, prop, want, _, _) when op in ["contains", "ncontains", "regex", "nregex"] do
    cond do
      not (is_binary(prop) and is_binary(want)) ->
        false

      op in ["contains", "ncontains"] ->
        String.contains?(prop, want) == (op == "contains")

      true ->
        case regex(want, prop) do
          nil -> false
          r -> r == (op == "regex")
        end
    end
  end

  defp apply_op(op, prop, want, semver, _) when op in ["gt", "gte", "lt", "lte"] do
    c = if semver, do: cmp_semver(prop, want), else: cmp_num(prop, want)

    cond do
      c == nil -> false
      op == "gt" -> c > 0
      op == "gte" -> c >= 0
      op == "lt" -> c < 0
      true -> c <= 0
    end
  end

  defp apply_op(op, prop, want, _, _) when op in ["in", "not_in"] do
    is_list(want) and Enum.any?(want, &equal?(prop, &1)) == (op == "in")
  end

  defp apply_op(op, prop, want, _, now) do
    fns = %{to_float: &to_float/1, semver: &semver/1, cmp_semver: &cmp_semver/2}
    Lucida.OpsV2.match?(op, prop, want, now || Lucida.OpsV2.parse_now(nil), fns)
  end

  # -- filters --------------------------------------------------------------------------------

  defp filter_matches?(fl, c, resolved) do
    op = to_string(fl["op"])
    want = fl["value"]
    now = Lucida.OpsV2.parse_now(c["now"])

    case fl["type"] do
      "app_version" ->
        v = c["app_version"] || ""
        op_match?(op, v, v != "", want, true, now)

      "flag" ->
        case resolved[to_string(fl["key"])] do
          nil -> false
          r -> op_match?(op, r.value, true, want, false, now)
        end

      "person" -> prop_match(c["person_properties"], fl, op, want, now)
      "group" -> prop_match((c["group_properties"] || %{})[fl["group_type"]], fl, op, want, now)
      "device" -> prop_match(c["device_properties"], fl, op, want, now)
      "geo" -> prop_match(c["geo_properties"], fl, op, want, now)
      _ -> false
    end
  end

  defp prop_match(props, fl, op, want, now) do
    props = props || %{}
    key = to_string(fl["key"])
    op_match?(op, props[key], Map.has_key?(props, key), want, false, now)
  end

  defp undecidable?(%{"type" => "flag"} = fl, resolved) do
    case resolved[to_string(fl["key"])] do
      %{reason: @requires_server} -> true
      _ -> false
    end
  end

  defp undecidable?(fl, _), do: fl["type"] == "cohort"

  # -- evaluation -----------------------------------------------------------------------------

  defp value_matches?(got, want) when is_boolean(want), do: if(is_boolean(got), do: got == want, else: want)
  defp value_matches?(got, want), do: got == want

  defp bucketing_key(f, c), do: unit_key(f["aggregation"] || %{}, c)

  defp unit_key(agg, c) do
    case agg["kind"] do
      "group" -> to_string((c["groups"] || %{})[agg["group_type"]] || "")
      "device" -> to_string(c["device_id"] || "")
      _ ->
        case c["bucketing_key"] do
          k when k in [nil, ""] -> to_string(c["distinct_id"] || "")
          k -> to_string(k)
        end
    end
  end

  defp pick_variant(f, cond_, key) do
    variants = f["variants"]
    override = cond_["variant_override"]
    found = if override not in [nil, ""], do: Enum.find(variants, &(&1["key"] == override))

    found ||
      pick_by_hash(variants, hash01("#{f["key"]}.#{f["salt"]}.variant.#{key}") * 100)
  end

  defp pick_by_hash(variants, h) do
    Enum.reduce_while(variants, 0.0, fn v, cum ->
      cum = cum + (v["rollout_pct"] || 0)
      if h < cum, do: {:halt, {:found, v}}, else: {:cont, cum}
    end)
    |> case do
      {:found, v} -> v
      _ -> List.last(variants)
    end
  end

  # A stored value of a sticky flag decides once a condition's filters passed (LC-EXT-29).
  defp sticky(f, cond_, idx, c) do
    stored = if f["sticky"], do: (c["sticky_assignments"] || %{})[f["key"]]
    variants = f["variants"] || []

    cond do
      stored == nil ->
        nil

      f["type"] == "multivariate" and variants != [] ->
        if Enum.any?(variants, &(&1["key"] == cond_["variant_override"])) do
          nil
        else
          v = Enum.find(variants, &(is_binary(stored) and &1["key"] == stored))
          v && %{value: v["key"], reason: "sticky_bucket", condition_index: idx, variant: v["key"], payload: v["payload"]}
        end

      stored == true ->
        %{value: true, reason: "sticky_bucket", condition_index: idx, variant: nil, payload: if(f["type"] == "json", do: f["payload"])}

      true ->
        nil
    end
  end

  defp app_context_allowed?(f, c) do
    want = f["app_contexts"] || []
    have = c["app_contexts"] || []
    want == [] or have == [] or Enum.any?(want, &(&1 in have))
  end

  def evaluate(f, c, resolved) do
    cond do
      !app_context_allowed?(f, c) -> off("app_context_excluded")
      !f["active"] -> off("inactive")
      f["kill_switch"] -> off("kill_switch")
      true -> prerequisites(f, c, resolved)
    end
  end

  defp prerequisites(f, c, resolved) do
    res =
      Enum.reduce_while(f["prerequisites"] || [], false, fn p, server ->
        case resolved[p["flag"]] do
          nil ->
            {:halt, off("prerequisite_missing")}

          %{reason: @requires_server} ->
            {:cont, true}

          r ->
            if r.reason == "prerequisite_cycle" or not value_matches?(r.value, p["value"]),
              do: {:halt, off("prerequisite_failed")},
              else: {:cont, server}
        end
      end)

    case res do
      true -> off(@requires_server)
      false -> bucket(f, c, resolved)
      r -> r
    end
  end

  defp bucket(f, c, resolved) do
    key = bucketing_key(f, c)
    ho = f["holdout"]
    ns = f["namespace"]

    per_condition = Enum.any?(f["conditions"] || [], & &1["aggregation"])

    cond do
      key == "" and (not per_condition or ho != nil or ns != nil) ->
        off("no_bucketing_key")

      ho && hash01("holdout.#{ho["salt"]}.#{key}") * 100 < ho["percentage"] ->
        off("holdout")

      ns && (ns["total"] || 0) > 0 && excluded?(ns, key) ->
        off("namespace_excluded")

      true ->
        conditions(f, c, resolved, key)
    end
  end

  defp excluded?(ns, key) do
    b = floor(hash01("namespace.#{ns["salt"]}.#{key}") * ns["total"])
    b < ns["start"] or b >= ns["end"]
  end

  defp conditions(f, c, resolved, key) do
    conds = f["conditions"] || []

    {r, skipped} =
      conds
      |> Enum.with_index()
      |> Enum.reduce_while({nil, 0}, fn {cond_, i}, {_, skipped} ->
        ckey = if cond_["aggregation"], do: unit_key(cond_["aggregation"], c), else: key

        if ckey == "" do
          {:cont, {nil, skipped + 1}}
        else
          case condition(f, cond_, i, c, resolved, ckey) do
            nil -> {:cont, {nil, skipped}}
            res -> {:halt, {res, skipped}}
          end
        end
      end)

    cond do
      r != nil -> r
      conds != [] and skipped == length(conds) -> off("no_bucketing_key")
      true -> off("no_condition_match")
    end
  end

  # nil: fall through to the next condition.
  defp condition(f, cond_, i, c, resolved, ckey) do
    filters = cond_["filters"] || []
    {undecided, local} = Enum.split_with(filters, &undecidable?(&1, resolved))

    cond do
      not Enum.all?(local, &filter_matches?(&1, c, resolved)) -> nil
      undecided != [] -> off(@requires_server, i)
      # the sticky store keys on the flag-level unit
      (s = if(cond_["aggregation"], do: nil, else: sticky(f, cond_, i, c))) != nil -> s
      hash01("#{f["key"]}.#{f["salt"]}.#{ckey}") * 100 >= (cond_["rollout_pct"] || 0) ->
        if f["early_exit"], do: off("out_of_rollout", i)

      true -> matched(f, cond_, i, ckey)
    end
  end

  defp matched(f, cond_, i, key) do
    if f["type"] == "multivariate" and (f["variants"] || []) != [] do
      v = pick_variant(f, cond_, key)
      %{value: v["key"], reason: "condition_match", condition_index: i, variant: v["key"], payload: v["payload"]}
    else
      %{value: true, reason: "condition_match", condition_index: i, variant: nil, payload: if(f["type"] == "json", do: f["payload"])}
    end
  end

  defp deps(f) do
    pre = for p <- f["prerequisites"] || [], do: p["flag"]
    fl = for cond_ <- f["conditions"] || [], x <- cond_["filters"] || [], x["type"] == "flag", do: x["key"]
    pre ++ fl
  end

  @doc "Evaluate every flag, resolving prerequisites and `flag` filters depth-first. Returns key => result map."
  def evaluate_all(flags, ctx) do
    by_key = Map.new(flags, &{&1["key"], &1})

    {out, _} =
      Enum.reduce(flags, {%{}, %{}}, fn f, acc -> visit(f["key"], by_key, ctx, acc) end)

    out
  end

  defp visit(key, by_key, ctx, {_, state} = acc) do
    f = by_key[key]
    if f == nil or Map.has_key?(state, key), do: acc, else: visit_flag(key, f, by_key, ctx, acc)
  end

  defp visit_flag(key, f, by_key, ctx, {out, state}) do
    {out, state, cyc} =
      Enum.reduce(deps(f), {out, Map.put(state, key, 1), false}, fn dep, {o, s, cyc} ->
        {o, s} = visit(dep, by_key, ctx, {o, s})
        cyc = cyc or s[dep] == 1 or match?(%{reason: "prerequisite_cycle"}, o[dep])
        {o, s, cyc}
      end)

    r = if cyc, do: off("prerequisite_cycle"), else: evaluate(f, ctx, out)
    {Map.put(out, key, r), Map.put(state, key, 2)}
  end
end

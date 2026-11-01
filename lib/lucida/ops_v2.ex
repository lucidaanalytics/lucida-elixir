defmodule Lucida.OpsV2 do
  @moduledoc """
  Spec v2 operators (`testdata/flags/README.md`, "Spec v2"); port of `go/internal/flageval/ops_v2.go`.
  `fns` carries the evaluator's `to_float/1`, `semver/1` and `cmp_semver/2` so both agree on coercion.
  """

  @unit %{"h" => 3600, "d" => 86_400, "w" => 7 * 86_400, "m" => 30 * 86_400, "y" => 365 * 86_400}
  @rfc ~r/\A\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(\.\d+)?(Z|[+-]\d{2}:\d{2})\z/
  @date ~r/\A(\d{4})-(\d{2})-(\d{2})\z/
  @string_ops ~w(icontains not_icontains starts_with not_starts_with ends_with not_ends_with)
  @range_ops ~w(semver_tilde semver_caret semver_wildcard)
  @cmp_ops ~w(semver_eq semver_neq semver_gt semver_gte semver_lt semver_lte)

  def relative_seconds(s) do
    case Regex.run(~r/\A-?(\d{1,6})([hdwmy])\z/, String.trim(s)) do
      [_, n, u] -> String.to_integer(n) * @unit[u]
      _ -> nil
    end
  end

  @doc "Evaluation clock (unix seconds, float): Context.now when it parses, else the wall clock."
  def parse_now(s) when is_binary(s), do: rfc(s) || System.os_time(:microsecond) / 1_000_000
  def parse_now(_), do: System.os_time(:microsecond) / 1_000_000

  defp rfc(s) do
    with true <- Regex.match?(@rfc, s),
         {:ok, dt, _} <- DateTime.from_iso8601(s) do
      DateTime.to_unix(dt, :microsecond) / 1_000_000
    else
      _ -> nil
    end
  end

  defp instant(v, _now, _rel) when is_number(v), do: v / 1

  defp instant(v, now, rel) when is_binary(v) do
    s = String.trim(v)

    cond do
      rel && relative_seconds(s) -> now - relative_seconds(s)
      (t = rfc(s)) != nil -> t
      true -> date(s)
    end
  end

  defp instant(_, _, _), do: nil

  defp date(s) do
    with [_, y, m, d] <- Regex.run(@date, s),
         {:ok, dt} <- Date.new(String.to_integer(y), String.to_integer(m), String.to_integer(d)) do
      DateTime.new!(dt, ~T[00:00:00], "Etc/UTC") |> DateTime.to_unix() |> Kernel./(1)
    else
      _ -> nil
    end
  end

  defp semver_range(op, want, parse) when is_binary(want) do
    parts = want |> String.trim() |> String.replace_prefix("v", "") |> String.split(".")

    if op == "semver_wildcard" do
      wildcard_range(parts, parse)
    else
      with p when p != nil <- parse.(want) do
        [a, b, c] = p ++ List.duplicate(0, max(0, 3 - length(p))) |> Enum.take(3)

        hi =
          cond do
            op == "semver_tilde" and length(parts) == 1 -> [a + 1, 0, 0]
            op == "semver_tilde" or (a == 0 and b > 0) -> [a, b + 1, 0]
            a > 0 -> [a + 1, 0, 0]
            true -> [0, 0, c + 1]
          end

        {[a, b, c], hi}
      end
    end
  end

  defp semver_range(_, _, _), do: nil

  defp wildcard_range(parts, parse) do
    cond do
      List.last(parts) not in ["*", "x", "X"] ->
        nil

      length(parts) == 1 ->
        {[0], [1_073_741_824]}

      true ->
        with lo when lo != nil <- parse.(parts |> Enum.drop(-1) |> Enum.join(".")) do
          {lo, List.update_at(lo, -1, &(&1 + 1))}
        end
    end
  end

  defp cmp_parts(a, b) do
    n = max(length(a), length(b))
    pad = fn l -> l ++ List.duplicate(0, n - length(l)) end
    {pa, pb} = {pad.(a), pad.(b)}

    cond do
      pa < pb -> -1
      pa > pb -> 1
      true -> 0
    end
  end

  @doc "Applies a v2 operator to a set property. Unknown operators never match."
  def match?(op, prop, want, _now, _fns) when op in @string_ops do
    if is_binary(prop) and is_binary(want), do: string_op(op, prop, want), else: false
  end

  def match?(op, prop, want, _now, fns) when op in ["between", "not_between"] do
    x = fns.to_float.(prop)

    case want do
      [lo, hi] when is_number(lo) and is_number(hi) and x != nil -> (x >= lo and x <= hi) == (op == "between")
      _ -> false
    end
  end

  def match?(op, prop, want, now, _fns) when op in ["is_date_before", "is_date_after"] do
    p = instant(prop, now, false)
    w = instant(want, now, true)

    cond do
      p == nil or w == nil -> false
      op == "is_date_before" -> p < w
      true -> p > w
    end
  end

  def match?(op, prop, want, _now, fns) when op in @cmp_ops do
    case fns.cmp_semver.(prop, want) do
      nil -> false
      c -> cmp_result(op, c)
    end
  end

  def match?(op, prop, want, _now, fns) when op in @range_ops do
    v = fns.semver.(prop)

    with true <- v != nil, {lo, hi} <- semver_range(op, want, fns.semver) do
      cmp_parts(v, lo) >= 0 and cmp_parts(v, hi) < 0
    else
      _ -> false
    end
  end

  def match?(_, _, _, _, _), do: false

  defp cmp_result("semver_eq", c), do: c == 0
  defp cmp_result("semver_neq", c), do: c != 0
  defp cmp_result("semver_gt", c), do: c > 0
  defp cmp_result("semver_gte", c), do: c >= 0
  defp cmp_result("semver_lt", c), do: c < 0
  defp cmp_result("semver_lte", c), do: c <= 0

  defp string_op(op, s, w) when op in ["icontains", "not_icontains"],
    do: String.contains?(String.downcase(s), String.downcase(w)) == (op == "icontains")

  defp string_op(op, s, w) when op in ["starts_with", "not_starts_with"],
    do: String.starts_with?(s, w) == (op == "starts_with")

  defp string_op(op, s, w), do: String.ends_with?(s, w) == (op == "ends_with")
end

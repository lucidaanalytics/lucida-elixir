defmodule Lucida.Client do
  @moduledoc """
  Server SDK client: a GenServer that batches events and sends them to `POST /v1/batch`.

  Every call names its `distinct_id`; there is no ambient identity. Delivery is at-least-once
  (a failed batch stays queued and is retried with exponential backoff; the per-event `uuid`
  dedupes server-side). 4xx responses other than 408/429 drop the batch (counted in `dropped/1`).

  Options for `start_link/1`: `:api_key` (required), `:host`, `:secret_key` (enables local flag
  evaluation), `:flush_at` (20), `:flush_interval_ms` (5000), `:max_queue_size` (1000),
  `:flag_poll_ms` (60000, definitions poll interval), `:only_evaluate_locally` (default true: flags
  undecidable locally read as `nil`; set false to ask `POST /v1/flags` for them), `:app_contexts`
  (flags scoped to other app contexts are dropped), `:disabled`, `:http` (module implementing `Lucida.Http`), `:name`.
  """
  use GenServer

  alias Lucida.{Context, Evaluator, Event, FlagSnapshot, RemoteFlags}

  # -- API ------------------------------------------------------------------------------------

  def start_link(opts) do
    gen_opts = if opts[:name], do: [name: opts[:name]], else: []
    GenServer.start_link(__MODULE__, opts, gen_opts)
  end

  def child_spec(opts), do: %{id: opts[:name] || __MODULE__, start: {__MODULE__, :start_link, [opts]}}

  @doc """
  opts: :groups, :timestamp, :uuid, :set, :set_once. `flags: snapshot` attaches a `Lucida.FlagSnapshot`'s
  `$feature/*` properties; `send_feature_flags: true` evaluates the distinct id's flags first (no exposures).
  """
  def capture(server, distinct_id, event, properties \\ %{}, opts \\ []) do
    props =
      cond do
        snap = opts[:flags] -> FlagSnapshot.event_props(properties, snap.values)
        opts[:send_feature_flags] -> FlagSnapshot.event_props(properties, evaluate_flags(server, distinct_id, groups: opts[:groups]).values)
        true -> properties
      end

    GenServer.cast(server, {:enqueue, Event.build(distinct_id, event, props, opts)})
  end

  @doc "Captures with the ambient `Lucida.Context` (set by `Lucida.Plug`): its distinct id and request properties; explicit `properties` win."
  def capture_in_context(server, event, properties \\ %{}, opts \\ []) do
    case Context.current() do
      %{distinct_id: id} = ctx when is_binary(id) ->
        capture(server, id, event, Map.merge(ctx.properties, properties), opts)

      _ ->
        {:error, :no_distinct_id}
    end
  end

  @doc "An identical call (same id and properties) already sent by this client is skipped."
  def identify(server, distinct_id, properties \\ nil, properties_set_once \\ nil),
    do: deduped(server, {:identify, distinct_id, properties, properties_set_once}, fn ->
      capture(server, distinct_id, "$identify", %{}, set: properties, set_once: properties_set_once)
    end)

  @doc "`$set` event updating person properties."
  def set_person_properties(server, distinct_id, properties),
    do: capture(server, distinct_id, "$set", %{}, set: properties)

  @doc "`$set` event with `$set_once`: only fills properties that are not set yet."
  def set_person_properties_once(server, distinct_id, properties),
    do: capture(server, distinct_id, "$set", %{}, set_once: properties)

  def create_alias(server, distinct_id, alias_id),
    do: capture(server, distinct_id, "$create_alias", %{"alias" => alias_id, "distinct_id" => distinct_id})

  def group_identify(server, group_type, group_key, properties \\ nil, distinct_id \\ nil) do
    props = %{"$group_type" => group_type, "$group_key" => group_key, "$group_set" => properties || %{}}
    deduped(server, {:group, group_type, group_key, distinct_id, properties}, fn ->
      capture(server, distinct_id || "$#{group_type}_#{group_key}", "$groupidentify", props)
    end)
  end

  defp deduped(server, call, fun) do
    key = :crypto.hash(:sha256, :erlang.term_to_binary(call))
    if GenServer.call(server, {:first_identity, key}), do: fun.(), else: :ok
  end

  @doc "Sends everything queued. `:ok`, or `:error` when a batch could not be delivered (kept for retry)."
  def flush(server), do: GenServer.call(server, :flush, 60_000)

  @doc "Flushes, then stops accepting events."
  def shutdown(server), do: GenServer.call(server, :shutdown, 60_000)

  def dropped(server), do: GenServer.call(server, :dropped)

  @doc "Fetches flag definitions (needs `:secret_key`). Keeps the previous ones on failure."
  def reload_feature_flags(server), do: GenServer.call(server, :reload, 30_000)

  @doc "Test hook / bootstrap: use these definitions without fetching."
  def set_definitions(server, flags), do: GenServer.call(server, {:defs, flags})

  @doc """
  `false`, `true` or a variant key; `nil` when unknown or undecidable locally (cohorts).
  opts: `:person_properties`, `:groups`, `:group_properties`, `:send_exposure` (default true),
  `:only_evaluate_locally` (overrides the client option), `:default` (returned when undecided).
  """
  def get_feature_flag(server, key, distinct_id, opts \\ []) do
    cfg = GenServer.call(server, :config)

    case local_flag(server, key, distinct_id, opts) do
      :undecided ->
        only_local = Keyword.get(opts, :only_evaluate_locally, cfg.only_local)
        remote = if only_local or cfg.disabled, do: nil, else: RemoteFlags.fetch(cfg, key, distinct_id, opts)
        if is_nil(remote), do: opts[:default], else: remote

      value ->
        value
    end
  end

  @doc "Payload of a remote-config flag, decrypted when stored encrypted. Needs `:secret_key`; `nil` when unknown or on failure."
  def get_remote_config_payload(server, key) do
    cfg = GenServer.call(server, :config)
    unless cfg.secret, do: raise(ArgumentError, "get_remote_config_payload requires :secret_key")
    if cfg.disabled, do: nil, else: RemoteFlags.remote_config(cfg, key)
  end

  defp local_flag(server, key, distinct_id, opts) do
    case local_results(server, distinct_id, opts)[key] do
      nil ->
        :undecided

      r ->
        if Keyword.get(opts, :send_exposure, true), do: GenServer.cast(server, {:expose, key, distinct_id, r.value})
        r.value
    end
  end

  @doc """
  Evaluates every flag decidable locally once and returns a `Lucida.FlagSnapshot` (no exposure events).
  Read it with `FlagSnapshot.get_flag/2` and attach it with `capture(..., flags: snapshot)`.
  opts as for `get_feature_flag/4` (without `:send_exposure`).
  """
  def evaluate_flags(server, distinct_id, opts \\ []) do
    all = local_results(server, distinct_id, opts)
    FlagSnapshot.new(Map.new(all, fn {k, r} -> {k, r.value} end), for({k, %{payload: p}} <- all, p != nil, into: %{}, do: {k, p}))
  end

  # Results decided locally: no app-context-excluded flags, nothing that needs the server.
  defp local_results(server, distinct_id, opts) do
    case GenServer.call(server, :eval_state) do
      {nil, _} ->
        %{}

      {defs, app_contexts} ->
        ctx = %{
          "distinct_id" => distinct_id,
          "groups" => opts[:groups] || %{},
          "person_properties" => opts[:person_properties] || %{},
          "group_properties" => opts[:group_properties] || %{},
          "app_contexts" => opts[:app_contexts] || app_contexts
        }

        defs
        |> Evaluator.evaluate_all(ctx)
        |> Enum.reject(fn {_, r} -> r.reason in ["requires_server", "app_context_excluded"] end)
        |> Map.new()
    end
  end

  def feature_enabled?(server, key, distinct_id, opts \\ []) do
    case get_feature_flag(server, key, distinct_id, opts) do
      nil -> nil
      v -> v != false
    end
  end

  # -- server ---------------------------------------------------------------------------------

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)

    s = %{
      api_key: Keyword.fetch!(opts, :api_key),
      host: String.trim_trailing(opts[:host] || "https://app.lucida.dev", "/"),
      secret: opts[:secret_key],
      flush_at: opts[:flush_at] || 20,
      interval: opts[:flush_interval_ms] || 5_000,
      max: opts[:max_queue_size] || 1_000,
      poll: opts[:flag_poll_ms] || 60_000,
      only_local: Keyword.get(opts, :only_evaluate_locally, true),
      identities: %{},
      identity_seq: 0,
      disabled: opts[:disabled] || false,
      http: opts[:http] || Lucida.Http.Httpc,
      queue: [],
      failures: 0,
      dropped: 0,
      defs: nil,
      app_contexts: opts[:app_contexts] || [],
      etag: nil,
      seen: MapSet.new()
    }

    Process.send_after(self(), :tick, s.interval)
    if s.secret && !s.disabled, do: {:ok, s, {:continue, :reload}}, else: {:ok, s}
  end

  @impl true
  def handle_continue(:reload, s) do
    {_, s} = reload(s)
    Process.send_after(self(), :poll, s.poll)
    {:noreply, s}
  end

  @impl true
  def handle_cast({:enqueue, _}, %{disabled: true} = s), do: {:noreply, s}

  def handle_cast({:enqueue, e}, s) do
    # shortcut: list append is O(n), n <= max_queue_size; use :queue if profiling says so.
    {queue, dropped} =
      if length(s.queue) >= s.max, do: {tl(s.queue), s.dropped + 1}, else: {s.queue, s.dropped}

    s = %{s | queue: queue ++ [e], dropped: dropped}
    if length(s.queue) >= s.flush_at, do: {:noreply, elem(drain(s), 1)}, else: {:noreply, s}
  end

  def handle_cast({:expose, key, distinct_id, value}, s) do
    seen = {distinct_id, key, value}

    if MapSet.member?(s.seen, seen) do
      {:noreply, s}
    else
      props = %{"$feature_flag" => key, "$feature_flag_response" => value, "locally_evaluated" => true}
      known = if MapSet.size(s.seen) >= 10_000, do: MapSet.new(), else: s.seen

      s = %{s | seen: MapSet.put(known, seen)}
      handle_cast({:enqueue, Event.build(distinct_id, "$feature_flag_called", props)}, s)
      |> then(fn {:noreply, s} -> handle_cast({:enqueue, Event.build(distinct_id, "$exposure", props)}, s) end)
    end
  end

  @impl true
  def handle_call(:flush, _from, s) do
    {res, s} = drain(s)
    {:reply, res, s}
  end

  def handle_call(:shutdown, _from, s) do
    {res, s} = drain(s)
    {:reply, res, %{s | disabled: true}}
  end

  def handle_call(:dropped, _from, s), do: {:reply, s.dropped, s}

  def handle_call(:config, _from, s),
    do: {:reply, Map.take(s, [:api_key, :secret, :host, :http, :only_local, :disabled]), s}

  # Bounded LRU of identify/group calls already sent: key => last-use sequence, oldest evicted past 1000.
  def handle_call({:first_identity, key}, _from, s) do
    fresh = not Map.has_key?(s.identities, key)
    seq = s.identity_seq + 1
    ids = Map.put(s.identities, key, seq)

    ids =
      if map_size(ids) > 1_000 do
        {oldest, _} = Enum.min_by(ids, fn {_, n} -> n end)
        Map.delete(ids, oldest)
      else
        ids
      end

    {:reply, fresh, %{s | identities: ids, identity_seq: seq}}
  end
  def handle_call(:defs, _from, %{disabled: true} = s), do: {:reply, nil, s}
  def handle_call(:defs, _from, s), do: {:reply, s.defs, s}
  def handle_call(:eval_state, _from, %{disabled: true} = s), do: {:reply, {nil, []}, s}
  def handle_call(:eval_state, _from, s), do: {:reply, {s.defs, s.app_contexts}, s}
  def handle_call({:defs, flags}, _from, s), do: {:reply, :ok, %{s | defs: flags}}

  def handle_call(:reload, _from, s) do
    {ok, s} = reload(s)
    {:reply, ok, s}
  end

  @impl true
  def handle_info(:tick, s) do
    {_, s} = drain(s)
    Process.send_after(self(), :tick, if(s.failures > 0, do: backoff(s.failures), else: s.interval))
    {:noreply, s}
  end

  def handle_info(:poll, s) do
    {_, s} = reload(s)
    Process.send_after(self(), :poll, s.poll)
    {:noreply, s}
  end

  def handle_info(_, s), do: {:noreply, s}

  @impl true
  def terminate(_reason, s), do: drain(s)

  # -- delivery -------------------------------------------------------------------------------

  defp drain(%{queue: []} = s), do: {:ok, s}

  defp drain(s) do
    {batch, rest} = Enum.split(s.queue, s.flush_at)
    payload = %{"api_key" => s.api_key, "batch" => batch, "sent_at" => Event.iso(nil)}

    case post(s, payload) do
      {:ok, st} when st in 200..299 -> drain(%{s | queue: rest, failures: 0})
      {:ok, st} when st in 400..499 and st not in [408, 429] -> drain(%{s | queue: rest, dropped: s.dropped + length(batch), failures: 0})
      _ -> {:error, %{s | failures: s.failures + 1}}
    end
  end

  # Exponential backoff with jitter: 50%..100% of min(30s, 1s * 2^n).
  defp backoff(n), do: round(min(30_000, 1_000 * Integer.pow(2, min(n, 10))) * (0.5 + :rand.uniform() / 2))

  defp post(s, payload) do
    body = JSON.encode!(payload)
    {body, url} = if byte_size(body) >= 1024, do: {:zlib.gzip(body), "#{s.host}/v1/batch?compression=gzip"}, else: {body, "#{s.host}/v1/batch"}

    case s.http.request(:post, url, [], body) do
      {:ok, %{status: st}} -> {:ok, st}
      other -> other
    end
  rescue
    e -> {:error, e}
  end

  defp reload(%{secret: nil} = s), do: {false, s}
  defp reload(%{disabled: true} = s), do: {false, s}

  defp reload(s) do
    headers = [{"authorization", "Bearer #{s.secret}"}] ++ if(s.etag, do: [{"if-none-match", s.etag}], else: [])

    with {:ok, %{status: st, body: body, headers: rh}} <- s.http.request(:get, s.host <> "/v1/flags/definitions", headers, nil),
         true <- st in 200..299 or st == 304 do
      if st == 304 do
        {true, s}
      else
        case JSON.decode(body) do
          {:ok, %{"flags" => flags}} when is_list(flags) ->
            {true, %{s | defs: flags, etag: List.keyfind(rh, "etag", 0) |> then(&(&1 && elem(&1, 1)))}}

          _ ->
            {false, s}
        end
      end
    else
      _ -> {false, s}
    end
  rescue
    _ -> {false, s}
  end
end

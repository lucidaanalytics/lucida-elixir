# lucida (Elixir)

Server SDK for Lucida. No hex dependencies: OTP `:httpc` for HTTP and the built-in `JSON` module, so it needs
Elixir >= 1.18 (OTP 25+).

```elixir
children = [{Lucida.Client, name: MyApp.Lucida, api_key: "lc_pk_...", secret_key: "lc_sk_...", host: "https://app.lucida.dev"}]

Lucida.Client.capture(MyApp.Lucida, "u1", "purchase", %{"total" => 12}, groups: %{"company" => "acme"})
Lucida.Client.identify(MyApp.Lucida, "u1", %{"plan" => "pro"})
Lucida.Client.create_alias(MyApp.Lucida, "u1", "anon-9")
Lucida.Client.group_identify(MyApp.Lucida, "company", "acme", %{"seats" => 5})
Lucida.Client.feature_enabled?(MyApp.Lucida, "new-checkout", "u1", person_properties: %{"plan" => "pro"})
Lucida.Client.shutdown(MyApp.Lucida)
```

- Events queue in a GenServer (bounded by `:max_queue_size`, oldest dropped) and go out as `POST /v1/batch` in
  batches of `:flush_at` (20), on a timer (`:flush_interval_ms`) and on `flush/1`. A failed batch stays queued and
  is retried with exponential backoff; 4xx other than 408/429 drops it. Each event has a uuid v7 (at-least-once,
  deduped server-side). Bodies over 1 KB are gzipped.
- With `:secret_key`, flag definitions load from `/v1/flags/definitions` (ETag aware, re-polled every `:flag_poll_ms`)
  and evaluate locally. `get_feature_flag/4` returns `false`, `true`, a variant key, or `nil` when unknown or the flag
  needs server data (cohorts); it records `$feature_flag_called` and `$exposure` once per user, flag and value.
- `fallbacks: %{"new-checkout" => false}` serves that value (reason `"fallback"`, no exposure) when a flag read fails or the
  flag is unknown; `get_feature_flag_details/4` returns `%{value, payload, variant, reason, condition_index, request_id,
  locally_evaluated}`. The per-call `:default` applies only when the key has no fallback.
- The HTTP port is `Lucida.Http`; pass `http: MyAdapter` to replace the default `Lucida.Http.Httpc`.

`mix test` runs the unit tests and the shared `testdata/flags` vectors (basic, g10, sticky, generated 10,000) plus
the `testdata/events/server_sdk.json` wire fixtures. Multi-kind contexts (`vectors_g18.json`) are not supported.

---

This repository is a read-only mirror of the Lucida monorepo (synced by a script, never edited by hand); releases and provenance attestations are built here by GitHub Actions. Issues are welcome, changes land upstream.

# Stable core API v1

RGP exposes a transport-neutral contract at `rgp.api.v1`. The existing JSON gateway is the offline adapter and identifies itself as `rgp.tools.v1`; both reuse the same parser, analysis, report, exercise, and learner-storage services as the CLI.

## Request and response

A core request has this shape:

```json
{"request_id":"r-1","operation":"stats","auth":{"principal":"local","learner_id":null,"hosted":false,"scopes":["read"]},"page":{"cursor":null,"limit":20},"payload":{}}
```

`operation` is one of `corpus`, `analyze`, `stats`, `compare`, `examples`, `learn`, `practice`, `explain`, or `progress`. Responses contain `request_id`, `ok`, an optional typed `error_code`, page information, and provenance. Deterministic responses identify `evidence_authority: "rgp"`, `api_version: "rgp.api.v1"`, and applicable snapshot/analyzer versions.

The JSON gateway uses the equivalent tool envelope:

```json
{"tool":"rgp.get_stats","input":"{\"construct\":\"map\"}","request_id":"r-1"}
```

Its response adds content-addressed `call_id` and `result_id`; `output` is the same JSON report rendered by `rgp compare map --json`.

## Operations and pagination

`rgp.get_stats`, `rgp.compare`, `rgp.find_examples`, and `rgp.get_topic` are read-only and database-backed. `rgp.find_examples` accepts `construct` and an optional `limit` from 1 through 100. `rgp.get_stats` accepts `construct` and optional `snapshot_id`. `rgp.compare` accepts a non-empty `constructs` array. The report and example outputs retain source/project provenance.

List endpoints use an opaque cursor and a requested limit from 1 through 100. Cursors are never interpreted by clients; an absent `next_cursor` means completion. Invalid cursors and limits are deterministic validation errors.

Stable error codes are `invalid_request`, `unauthenticated`, `forbidden`, `not_found`, `conflict`, `invalid_cursor`, `limit_exceeded`, `cancelled`, `unavailable`, and `failed`. The gateway additionally exposes `database_required`, `policy_denied`, and exercise-limit errors for its adapter boundary.

## Long-running work and cancellation

Corpus sync, repository analysis, and hosted generation are jobs, not blocking requests. A job returns an opaque ID and `queued`, `running`, `completed`, `failed`, or `cancelled` state plus bounded progress. Implementations must call the cooperative checkpoint before each file/batch boundary. Cancellation is idempotent: a queued/running job transitions to `cancelled`, and a completed job is unchanged. `src/api.zig` tests the state transition and checkpoint error.

## Hosted isolation and authentication

Offline callers use a local principal and SQLite database. Hosted adapters must authenticate before dispatch, set `hosted=true`, and provide a server-issued `learner_id`; missing identity is `unauthenticated`. Learner mutations and progress reads must call `authorizeLearner`, which rejects a request whose learner ID differs from the authenticated subject. Tenant/database selection belongs to the host adapter; request payloads cannot select another tenant. Scope checks are separate from adapter capabilities, and no provider credential is accepted by the core API.

The isolation and pagination boundary is tested in `src/api.zig`; gateway permission, cancellation, redaction, and policy tests are in `src/agent/gateway.zig`. No hosted server is enabled by default, so offline operation remains filesystem/SQLite-only.

## Reproducible validation

```bash
zig build test
zig build run -- compare each for --json
```

The gateway integration tests exercise parser, lesson, exercise, report, and error paths. Report-backed gateway operations call the same `reports` functions as the CLI, so their JSON output and provenance originate from the same deterministic query path.

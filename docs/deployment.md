# Web/API foundation deployment

This is the reproducible Phase 11 deployment boundary. RGP is currently a
SQLite-backed core plus a dependency-free static web client; a host supplies
the HTTP adapter for `POST /api/tools` described in [`api.md`](api.md).
There is no hosted server in this repository and no required provider account.

## Deployment inputs

Build with the pinned Zig version from `.zigversion` and link the target's
SQLite 3 and C runtime:

```sh
zig build -Doptimize=ReleaseSmall
mkdir -p var
./zig-out/bin/rgp --version
```

Serve `web/` as static files. Configure the adapter with `RGP_API_ENDPOINT`
(or `window.RGP_API_ENDPOINT`) for the `/api/tools` URL, an opaque learner
identity supplied as `window.RGP_LEARNER_ID`, and a SQLite database path kept
outside the static asset directory. Hosted adapters authenticate first, set
`hosted=true`, supply the server-issued learner ID, and apply
`authorizeLearner`; tenant/database selection belongs to the host.

## Migrations

Opening a database runs append-only migrations in `src/storage/sqlite.zig`
inside individual `BEGIN IMMEDIATE` transactions. The current schema version
is `latest_schema_version` (currently 13). Verify it before serving traffic:

```sh
sqlite3 var/rgp.sqlite 'PRAGMA foreign_keys=ON;'
zig build test
```

Do not edit an applied migration or manually change `schema_migrations`. Append
new migrations, test fresh and existing databases, and deploy before dependent
code. A newer on-disk schema is rejected rather than downgraded.

## Backups and restore

Stop writers or use SQLite's online backup mechanism for a consistent copy:

```sh
mkdir -p backups
sqlite3 var/rgp.sqlite '.backup backups/rgp-backup.sqlite'
sqlite3 backups/rgp-backup.sqlite 'PRAGMA integrity_check;'
sha256sum backups/rgp-backup.sqlite
```

Record the source revision, schema version, UTC timestamp, database filename,
and checksum. Restore only while the adapter is stopped, then open the database
with the release binary so migrations and foreign-key checks run before traffic
resumes. Keep one tested restore copy separate from the host.

## Optional agent setup

The `fx` adapter is optional and process-local:

```sh
rgp agent list
rgp agent use fx
rgp agent status
rgp ask --agent fx 'Explain this lesson'
```

Configure the executable and provider through the adapter's own mechanism. RGP
may record `auth_env` but never reads or stores the credential. If fx is absent
or unauthenticated, `ask` fails explicitly and offline analysis, reports,
lessons, exercises, and progress continue to work. See [`agents.md`](agents.md).

## Release evidence and deferred boundaries

Run `bash scripts/release-check.sh`, then `bash scripts/release-check.sh package`
and record `sha256sum dist/*.tar.gz`. `zig build test` includes the end-to-end
gateway test with isolated learner data. Editor integrations, WASM packaging,
classroom administration, MCP transport, and autonomous subagent workflows are
deferred possibilities, not required deployment components for this release.

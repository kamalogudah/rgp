# Configuration contracts

`corpus.toml`, `taxonomy.toml`, and `idioms.toml` are versioned, declarative
inputs to the deterministic analyzer. They are checked into the repository;
the examples at the repository root are a schema-version-1 offline fixture.
Parsing configuration must never require network access.

All three files require an integer `schema_version` at the document root.
Version `1` is the only supported version. A reader must reject a missing,
non-integer, or unsupported version before using any other value. Unknown keys
are rejected at every level so spelling mistakes cannot silently change an
analysis.

## `corpus.toml`

`corpus.toml` defines the repositories that `rgp analyze` and
`rgp analyze --corpus` process. The two forms are aliases: both analyze every
configured repository at its declared revision. They do not infer the current
directory and do not contact a remote. A positional target is the only way to
request one-off analysis:

```text
rgp analyze <repo-or-path>
rgp analyze                 # same as: rgp analyze --corpus
rgp analyze --corpus
```

Each `[[repository]]` requires:

- `id`: unique, lowercase ASCII identifier matching `[a-z0-9][a-z0-9_-]*`.
- `source`: HTTPS Git URL or repository-local path. A local path is resolved
  relative to `corpus.toml`; it is not fetched.
- `revision`: exactly 40 lowercase hexadecimal characters naming an immutable
  Git commit.
- `include`: non-empty list of repository-relative glob patterns.
- `exclude`: list of repository-relative glob patterns; it may be empty.

`[corpus].offline` is required and must be `true` for the checked-in reference
corpus. It means analysis consumes already materialized snapshots only. A
future explicit sync command may fetch `source`, but must verify that the
result resolves to `revision` before saving it.

The analyzer records `id`, `source`, `revision`, the configuration schema
version, and the analyzer version with every observation and aggregate. This
is the minimum provenance needed to reproduce a statistic offline from a
saved snapshot.

Examples of required diagnostics:

```text
error: corpus.toml: schema_version 2 is unsupported (supported: 1)
error: corpus.toml: repository `rack`: revision must be a 40-character lowercase Git commit SHA
error: corpus.toml: duplicate repository id `rgp-fixture`
error: corpus.toml: `rgp analyze --corpus` requires an initialized local snapshot for `rgp-fixture` at e8cbd95f6fe039a95d8e7a1c86ea4c14a96bbe65; run `rgp corpus sync` explicitly
```

## `taxonomy.toml`

`taxonomy.toml` defines the user-facing learning and reporting hierarchy.
Each `[[topic]]` requires a unique `id` matching the corpus identifier rule
with optional dot-separated segments, and a non-empty `title`. `parent` is
optional; when present it must name another topic. `constructs` is optional,
but when present must contain unique non-empty construct IDs.

Parents must exist, a topic cannot parent itself, and the parent graph must be
acyclic. The taxonomy is educational metadata: Prism node names and parser
internals are not valid topic IDs unless deliberately mapped as constructs.

Examples of required diagnostics:

```text
error: taxonomy.toml: topic `collections.cardinality`: parent `collections` does not exist
error: taxonomy.toml: topic parent graph contains a cycle: collections -> collections.cardinality -> collections
error: taxonomy.toml: duplicate topic id `collections`
```

## `idioms.toml`

`idioms.toml` maps documented idioms to the taxonomy without embedding parser
logic in configuration. Each `[[idiom]]` requires a unique `id`, non-empty
`title`, existing taxonomy `topic`, and non-empty, unique
`required_constructs`. `comparison_idiom`, when present, must name another
idiom ID; an idiom cannot compare to itself.

The analyzer owns the executable pattern and semantic-safety rules for an
idiom. Configuration only declares stable identity, educational placement, and
the constructs that the implementation must account for. This preserves a
deterministic analyzer and prevents TOML from becoming an unreviewed rule
language.

Examples of required diagnostics:

```text
error: idioms.toml: idiom `manual_collection_transformation`: topic `collections` does not exist in taxonomy.toml
error: idioms.toml: idiom `map`: comparison_idiom cannot reference itself
error: idioms.toml: duplicate idiom id `map`
```

## Validation evidence

The reference files use only schema version 1 and cross-reference one another:
both idiom topics exist in `taxonomy.toml`, and the corpus entry has a unique ID and a 40-character revision. Until the configuration loader lands, these fixtures
are the normative, reviewable contract; its parser tests must cover every
diagnostic above and reject unknown keys. The existing offline core check is:

```sh
zig fmt --check src build.zig
zig build
zig build test
```

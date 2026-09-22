# RGP — Ruby: The Good Parts

RGP is a Zig application for learning Ruby from evidence in real Ruby code.
It will parse Ruby with libprism, preserve source provenance, classify idioms,
and use that deterministic evidence for reports and learning workflows.

## Requirements

RGP supports **Zig 0.16.0**. The exact version is pinned in `.zigversion` and
the package metadata declares the same minimum supported version.

## libprism

The pinned, vendored libprism C source, MIT license, offline build approach,
verification, and upgrade procedure are in [`docs/libprism.md`](docs/libprism.md).

## CI targets

CI verifies formatting, builds, and tests with that exact Zig version on the
native GitHub-hosted runners for Linux (`ubuntu-latest`), macOS
(`macos-latest`), and Windows (`windows-latest`). There are currently no
third-party Zig package dependencies, so the checked-in source and pinned
toolchain are sufficient for the core workflow to run offline after Zig is
installed.

## SQLite storage

The core stores analyzer facts in SQLite with foreign keys enabled and
append-only migrations. A completed analysis run and its raw observations are
written in one transaction; failed analysis can instead be retained as a
separate failed run. Each run records RGP, Prism, classifier, taxonomy, and
corpus snapshot versions.

Run the offline migration and transaction regression coverage with `zig build test`.

## Configuration contracts

The versioned corpus, taxonomy, and idiom configuration contracts—including
offline behavior and required diagnostics—are documented in
[`docs/configuration.md`](docs/configuration.md).

## Local workflow

```sh
zig fmt --check src build.zig
zig build
zig build test
zig build run -- --help
zig build run -- --version
```

Use `zig fmt src build.zig` to apply formatting before committing.

## Release validation and packaging

The first offline Learning MVP has a repeatable release checklist, acceptance
evidence, supported targets, dependency provenance, packaging instructions, and
known limitations in [`docs/release.md`](docs/release.md). Run the complete
offline validation with:

```sh
bash scripts/release-check.sh
```

Add `package` to create a native `dist/*.tar.gz` artifact and then record its
SHA-256 checksum.

## CLI

```text
rgp --help
rgp --version
```

### Corpus management

```text
rgp corpus add <source> [--revision <sha>] [--category <cat>] [--id <id>]
rgp corpus remove <repo>
rgp corpus list
rgp corpus sync
```

`corpus.toml` pins every repository to an exact 40-character Git commit and a
category such as `rails`, `framework`, `library`, `tool`, or `standard`.
`rgp corpus sync` materializes remote snapshots with shallow Git fetches and
verifies the working tree matches the pinned revision. Removing an entry leaves
its cached snapshot in place by default.

Unknown commands exit with status 2 and explain how to view the available
commands.

## Architecture

`src/root.zig` is the reusable, deterministic RGP core. It owns domain types
and command parsing without process or I/O dependencies. `src/main.zig` is the
thin command-line adapter that reads process arguments, renders output, and
sets exit status.

Future repository ingestion, libprism parsing, observations, storage, reports,
learning, and agent adapters build on the core. Coding agents consume RGP's
deterministic analysis; they never create corpus facts or statistics.

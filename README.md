# RGP — Ruby: The Good Parts

RGP is a Zig application for learning Ruby from evidence in real Ruby code.
It will parse Ruby with libprism, preserve source provenance, classify idioms,
and use that deterministic evidence for reports and learning workflows.

## Requirements

RGP supports **Zig 0.16.0**. The exact version is pinned in `.zigversion` and
the package metadata declares the same minimum supported version.

## Local workflow

```sh
zig fmt --check src build.zig
zig build
zig build test
zig build run -- --help
zig build run -- --version
```

Use `zig fmt src build.zig` to apply formatting before committing.

## CLI

```text
rgp --help
rgp --version
```

Unknown commands exit with status 2 and explain how to view the available
commands. The first functional commands are introduced as their roadmap work
lands.

## Architecture

`src/root.zig` is the reusable, deterministic RGP core. It owns domain types
and command parsing without process or I/O dependencies. `src/main.zig` is the
thin command-line adapter that reads process arguments, renders output, and
sets exit status.

Future repository ingestion, libprism parsing, observations, storage, reports,
learning, and agent adapters build on the core. Coding agents consume RGP's
deterministic analysis; they never create corpus facts or statistics.

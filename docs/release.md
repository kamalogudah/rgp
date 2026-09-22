# RGP first offline learning MVP release

This document is the release checklist and reproducible evidence record for
the first Learning MVP. It is runnable from a clean checkout and does not
require Ruby, RubyGems, an AI provider, or a network connection for core
validation.

## Supported build targets

The source is tested with Zig `0.16.0`, recorded in [`.zigversion`](../.zigversion).
The supported release targets are native Linux, macOS, and Windows builds:

| Target | Build command | Runtime dependency |
| --- | --- | --- |
| Linux x86_64 | `zig build -Dtarget=x86_64-linux-gnu -Doptimize=ReleaseSmall` | libc and SQLite 3 |
| macOS x86_64 | `zig build -Dtarget=x86_64-macos -Doptimize=ReleaseSmall` | macOS libc and SQLite 3 |
| macOS arm64 | `zig build -Dtarget=aarch64-macos -Doptimize=ReleaseSmall` | macOS libc and SQLite 3 |
| Windows x86_64 | `zig build -Dtarget=x86_64-windows-gnu -Doptimize=ReleaseSmall` | MinGW C runtime and SQLite 3 |

The release artifact is a native executable, not a statically linked SQLite
bundle. A target build must be validated on a machine with that target's C
runtime and SQLite library available.

## Clean-install workflow

Install Zig `0.16.0`, obtain this repository (or its source archive), and run:

```sh
zig fmt --check src build.zig
zig build
zig build test
bash fixtures/corpus/regression_gate.sh
zig build run -- --help
zig build run -- --version
```

The regression gate uses only checked-in files, creates a temporary SQLite
database, and verifies cold/incremental analysis, all 34 fixture observations,
golden JSON reports, taxonomy reports, and fresh-vs-incremental equivalence.
For a release-style build and smoke test, run `bash scripts/release-check.sh`.

## Acceptance-criteria evidence

| Requirement | Reproducible evidence |
| --- | --- |
| Local ingestion | `zig build test` and `fixtures/corpus/regression_gate.sh` analyze a checked-in local Ruby fixture. |
| GitHub/Git ingestion | `zig build test` covers Git URL parsing, revision pinning, local Git commits, and sync diagnostics. A real remote fetch is separate: `rgp corpus add https://github.com/ORG/REPO --revision <40-char-sha>` then `rgp corpus sync`. |
| SQLite persistence | `zig build test` covers migrations, transactions, cache invalidation, observations, exercise attempts, and lesson progress. |
| 20+ measurements | `docs/constructs.md` documents 23 supported construct measurements; the fixture gate asserts the catalog and a 34-observation denominator. |
| 5+ detectors | `src/analysis/idioms.zig` has versioned source-aware rules; `scripts/release-check.sh` checks five detector IDs in JSON output. |
| Taxonomy | `zig build test` validates the checked-in taxonomy and idiom mappings; JSON reports are golden-tested. |
| Terminal and JSON output | CLI tests and the corpus gate cover terminal output plus `compare`/`report` JSON goldens. |
| Ten lessons | `rgp learn` lists ten lessons; `scripts/release-check.sh` counts the ten entries. |
| Exercises and progress | `src/exercises.zig` provides deterministic syntax/static validation and records attempts in SQLite; lesson progress is persisted by `src/storage/sqlite.zig`. |
| Beginner path with AI disabled | `rgp learn`, `analyze`, `report`, `compare`, and `idioms` have no AI/provider dependency; the complete regression gate runs offline. |

## Packaging

The release package contains the native `rgp` executable, README, release
documentation, configuration contracts, and the vendored libprism license.

```sh
bash scripts/release-check.sh package
sha256sum dist/*.tar.gz
```

`dist/` is generated and is not committed. The source checkout is also a
supported distribution because it includes pinned libprism source and the
configuration fixtures needed for offline builds.

## Dependency and artifact provenance

- RGP has no Zig package dependencies in `build.zig.zon`.
- libprism `v1.9.0` is vendored, pinned, and MIT licensed; its source and
  license hashes are recorded in [`libprism.md`](libprism.md).
- SQLite is linked from the target system and is not redistributed by RGP;
  consult the installed SQLite distribution for its public-domain notice.
- The repository does not currently declare a separate RGP project license.
  Maintainers must add one before publishing a package that grants reuse rights.

## Known limitations

- GitHub ingestion requires Git and network access while resolving or
  materializing a remote pinned snapshot. Analysis of an already materialized
  snapshot is offline.
- The analyzer is syntax/evidence based; it does not claim semantic
  equivalence, execution behavior, or prevalence beyond the analyzed corpus.
- The offline exercise validator parses submissions and applies conservative
  static checks. It does not execute Ruby; results are marked
  `runtime_unavailable` rather than guessed.
- Release binaries depend on the target C runtime and SQLite library.
- The fixture corpus is small and hand-reviewed; it validates the release path,
  not production-scale performance or broad Ruby compatibility.

## Maintainer release checklist

1. Confirm the worktree is clean and update version/provenance facts.
2. Run `bash scripts/release-check.sh` on each supported target.
3. Run `bash scripts/release-check.sh package` and record SHA-256 checksums.
4. Inspect the archive contents and attach the archive plus checksum file.
5. Publish the source revision, artifact checksums, target, and limitations.

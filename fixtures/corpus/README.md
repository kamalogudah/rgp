# First analyzer regression corpus

This directory contains a small, hand-reviewed, offline corpus used by the
release regression gate for the first analyzer milestone (plan.md, sections
28, 29, and 35).

## Contents

| File | Purpose |
| --- | --- |
| `first_analyzer.rb` | A single Ruby file with one occurrence of every Phase 3 construct plus nine block forms. Counts are documented in the file header. |
| `corpus.toml` | An offline corpus configuration that references only the local `first_analyzer.rb` file. No remote repositories are required. |

## Provenance

`first_analyzer.rb` is an original RGP regression fixture. It does not contain
code copied from any external project, so there is no third-party license to
reconcile.

The corpus is analyzed through the same pipeline as production repositories:

- libprism parses the source into an AST.
- RGP extracts observations and stores them in SQLite.
- `rgp compare` and `rgp report` commands produce counts, percentages, project
distribution, and provenance from those observations.

## Hand-reviewed expected counts

For `first_analyzer.rb`:

| Construct | Count |
| --- | --- |
| module | 1 |
| class | 1 |
| def | 1 |
| if | 1 |
| unless | 1 |
| case | 1 |
| while | 1 |
| until | 1 |
| for | 1 |
| each | 1 |
| times | 1 |
| map | 1 |
| collect | 1 |
| select | 1 |
| filter | 1 |
| reject | 1 |
| reduce | 1 |
| inject | 1 |
| size | 1 |
| length | 1 |
| count | 1 |
| rescue | 1 |
| block | 9 |
| **Total observations** | **34** |

## Running the regression gate

The gate is exercised automatically by `zig build test`. It can also be run
manually from this directory:

```bash
rgp analyze
rgp compare each for
rgp compare size count length
rgp compare map collect
rgp compare select filter reject
rgp compare reduce inject
rgp compare if unless
rgp compare case if
rgp compare block
rgp report conditionals
rgp report collections
```

All commands operate offline against `first_analyzer.rb`; no Git clone is
performed.

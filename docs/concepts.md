# Repository concept maps and cohort comparisons

`rgp learn-repo` is an offline report over completed observations in
`.rgp/rgp.db`:

```bash
rgp learn-repo https://github.com/hanami/hanami \
  --compare-cohort rails --compare-cohort hanami
```

The map lists observed constructs, a stable representative source span
(`origin@commit file:line:column` plus byte offsets), learner prerequisites,
known concepts absent from the repository, and observed constructs outside the
curated concept vocabulary. A span is evidence of syntax only; it is not a
claim of semantic equivalence.

Each cohort section reports its observation denominator, construct count and
percentage, project coverage, a conservative confidence label, applied cohort
filter, snapshot ID, and analyzer versions. Empty cohorts are rendered as
absent/unknown rather than as zero-confidence facts. The final bias note calls
out the pinned corpus, project selection, file-classification filters, and
incomplete runs.

Reproducible validation:

```bash
zig build test
zig build
```

Both commands are offline. The report reads only completed local runs and
retains commit SHAs and source offsets from the storage layer.

## Guided reading

After a repository has been ingested with `rgp analyze <path>`, start a deterministic, read-only walkthrough from its completed observations:

```bash
rgp learn-repo <origin> --concept map --learner ada --session hanami-map
rgp learn-repo <origin> --concept map --learner ada --session hanami-map --answer "map transforms each item"
```

Questions include the repository origin, pinned commit, file path, line/column, and byte offsets. Answers are checked against the requested observed construct and accepted answers are stored as `repository_reading_answers` plus attributable `competency_evidence`. The walkthrough never writes repository source files.


## Historical snapshot comparisons

Compare pinned analysis snapshots with raw count changes and denominator-normalized percentage-point changes:

```bash
rgp compare each for --from-snapshot 1 --to-snapshot 2 --json
```

The result reports observation and project composition by cohort, exposing corpus membership and denominator changes. Comparisons reject classifier or taxonomy version mismatches; reanalyze both pinned snapshots with the same analyzer versions before retrying.

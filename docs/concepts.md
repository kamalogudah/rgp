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

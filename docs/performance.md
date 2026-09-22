# Corpus performance evidence

The documented workload is the checked-in offline corpus in
`fixtures/corpus`: one Ruby file, one pinned snapshot, and the report queries
used by `fixtures/corpus/regression_gate.sh`. It requires no network or Ruby
installation.

Run the implementation checks with:

```sh
zig build test
zig build -Doptimize=ReleaseFast
bash fixtures/corpus/regression_gate.sh
```

For throughput and memory, run the workload from a temporary directory so the
database starts cold. The following command records elapsed seconds and peak
resident memory for cold analysis, incremental analysis, and 100 identical
report queries:

```sh
work=$(mktemp -d /tmp/rgp-bench.XXXXXX)
cp fixtures/corpus/corpus.toml fixtures/corpus/first_analyzer.rb "$work"/
/usr/bin/time -f 'cold_analyze elapsed=%e max_rss_kb=%M' sh -c \
  'cd "$1" && rgp analyze >/dev/null' sh "$work"
/usr/bin/time -f 'cached_analyze elapsed=%e max_rss_kb=%M' sh -c \
  'cd "$1" && rgp analyze >/dev/null' sh "$work"
/usr/bin/time -f 'report_100 elapsed=%e max_rss_kb=%M' sh -c \
  'cd "$1" && i=0; while [ "$i" -lt 100 ]; do rgp report collections --json >/dev/null; i=$((i+1)); done' sh "$work"
sqlite3 "$work/.rgp/rgp.db" \
  'select count(*) observations from observations; select count(*) cache_entries from statistics_cache;'
rm -rf "$work"
```

Recorded ReleaseFast run on 2026-09-22 (Zig 0.16.0, SQLite 3.51.0,
container-local CPU): cold analysis `0.23s / 11,440 KiB`, incremental analysis
`0.06s / 9,936 KiB`, and 100 reports `5.44s / 9,492 KiB`. The resulting
database contained 34 observations and 10 aggregate-cache entries.

The current extractor records `break` (2) and `raise` (1), so this workload
has 34 raw observations. The checked-in goldens include those deterministic
facts and make the regression gate self-consistent.

The write path now reuses a prepared observation INSERT for the whole atomic
batch and memoizes construct IDs per run. Aggregate counts and analyzer
versions are cached by the complete filter, snapshot, and construct key.
Successful analysis invalidates the cache inside the same transaction, so a
failed transaction cannot publish partial facts or stale aggregates.

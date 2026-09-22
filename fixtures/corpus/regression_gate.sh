#!/usr/bin/env bash
set -euo pipefail

# This gate deliberately uses only files checked into this repository. It
# never invokes git, Ruby, a package manager, or a network client.
fixture_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
project_dir=$(CDPATH= cd -- "$fixture_dir/../.." && pwd)
binary=${RGP_BINARY:-"$project_dir/zig-out/bin/rgp"}
golden_dir="$fixture_dir/golden"

if [[ ! -x "$binary" ]]; then
    echo "regression gate: missing executable: $binary" >&2
    echo "build RGP first (for example: zig build)" >&2
    exit 1
fi

work_root=$(mktemp -d "${TMPDIR:-/tmp}/rgp-corpus-gate.XXXXXX")
trap 'rm -rf "$work_root"' EXIT

make_workspace() {
    local destination=$1
    mkdir -p "$destination"
    cp "$fixture_dir/corpus.toml" "$fixture_dir/first_analyzer.rb" "$destination/"
}

run_cli() {
    local workspace=$1
    shift
    (cd "$workspace" && "$binary" "$@")
}

assert_golden() {
    local workspace=$1
    local golden=$2
    shift 2
    local actual="$work_root/$(basename "$golden").actual"
    run_cli "$workspace" "$@" >"$actual"
    cmp -s "$golden_dir/$golden" "$actual" || {
        echo "regression gate: golden mismatch for $*" >&2
        diff -u "$golden_dir/$golden" "$actual" >&2 || true
        exit 1
    }
}

incremental="$work_root/incremental"
fresh="$work_root/fresh"
make_workspace "$incremental"
make_workspace "$fresh"

first_run=$(run_cli "$incremental" analyze)
second_run=$(run_cli "$incremental" analyze)
fresh_run=$(run_cli "$fresh" analyze)

[[ "$first_run" == *"[ok] rgp-first-analyzer: 1 analyzed, 0 skipped"* ]] || {
    echo "regression gate: first analysis did not analyze exactly one fixture" >&2
    exit 1
}
[[ "$second_run" == *"[ok] rgp-first-analyzer: 0 analyzed, 1 skipped"* ]] || {
    echo "regression gate: repeated analysis did not reuse the fixture" >&2
    exit 1
}
[[ "$fresh_run" == *"[ok] rgp-first-analyzer: 1 analyzed, 0 skipped"* ]] || {
    echo "regression gate: fresh analysis did not analyze exactly one fixture" >&2
    exit 1
}

# The first analyzer flow and the complete hand-reviewed catalog are both
# golden. The latter also asserts the 34-observation denominator and every
# expected construct count, including the nine block observations.
assert_golden "$incremental" compare_each_for.json compare each for --json
assert_golden "$incremental" compare_times_while.json compare times while --json
assert_golden "$incremental" compare_cardinality.json compare size count length --json
assert_golden "$incremental" report_conditionals.json report conditionals --json
assert_golden "$incremental" report_collections.json report collections --json
all_counts=$(run_cli "$incremental" compare module class def if unless case while until for each times map collect select filter reject reduce inject size length count rescue block --json)
[[ "$all_counts" == *'"denominator":34'* ]] || { echo "regression gate: aggregate denominator is not 34" >&2; exit 1; }
while IFS="=" read -r construct expected; do
    [[ -z "$construct" ]] && continue
    [[ "$all_counts" == *"\"construct\":\"$construct\""*"\"count\":$expected,"* ]] || { echo "regression gate: expected $construct=$expected" >&2; exit 1; }
done < "$fixture_dir/expected_counts.txt"

for command in \
    "compare each for --json" \
    "compare times while --json" \
    "compare size count length --json" \
    "report conditionals --json" \
    "report collections --json"; do
    # shellcheck disable=SC2086
    incremental_output=$(run_cli "$incremental" $command)
    fresh_output=$(run_cli "$fresh" $command)
    [[ "$incremental_output" == "$fresh_output" ]] || {
        echo "regression gate: fresh and incremental reports differ for $command" >&2
        diff -u <(printf '%s\n' "$fresh_output") <(printf '%s\n' "$incremental_output") >&2 || true
        exit 1
    }
done

echo "corpus regression gate: passed (pinned offline fixture, golden reports, incremental equivalence)"

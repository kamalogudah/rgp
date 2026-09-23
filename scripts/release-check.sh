#!/usr/bin/env bash
set -euo pipefail

project_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$project_dir"

zig_version=$(tr -d '[:space:]' < .zigversion)
app_version=$(sed -n 's/.*\.version = "\([^"]*\)".*/\1/p' build.zig.zon)
if [[ "$(zig version)" != "$zig_version" ]]; then
    echo "release check: expected Zig $zig_version, found $(zig version)" >&2
    exit 1
fi

echo "[1/7] formatting"
zig fmt --check src build.zig
echo "[2/7] debug tests"
zig build test
echo "[3/7] release build"
zig build -Doptimize=ReleaseSmall
echo "[4/7] offline corpus regression gate"
RGP_BINARY="$project_dir/zig-out/bin/rgp" bash fixtures/corpus/regression_gate.sh
echo "[5/7] CLI smoke checks"
./zig-out/bin/rgp --help >/dev/null
./zig-out/bin/rgp --version | grep -F "rgp " >/dev/null

echo "[6/7] learning and detector inventory"
lesson_count=$(./zig-out/bin/rgp learn | awk '/^[0-9]+\./ { count += 1 } END { print count + 0 }')
[[ "$lesson_count" -eq 16 ]] || { echo "release check: expected 16 lessons, found $lesson_count" >&2; exit 1; }
idioms=$(./zig-out/bin/rgp idioms fixtures/corpus/first_analyzer.rb --json)
for idiom in collection_iteration fixed_iteration collection_transformation collection_filter aggregation; do
    grep -F "\"idiom_id\":\"$idiom\"" <<<"$idioms" >/dev/null || {
        echo "release check: fixture did not exercise detector $idiom" >&2
        exit 1
    }
done

if [[ "${1:-check}" == "package" ]]; then
    echo "[7/7] package artifact"
    mkdir -p dist
    target=$(uname -s | tr '[:upper:]' '[:lower:]')-$(uname -m)
    name="rgp-${app_version}-${target}"
    stage=$(mktemp -d "${TMPDIR:-/tmp}/rgp-release.XXXXXX")
    trap 'rm -rf "$stage"' EXIT
    mkdir -p "$stage/$name/docs" "$stage/$name/vendor/libprism"
    cp zig-out/bin/rgp README.md "$stage/$name/"
    cp docs/release.md docs/deployment.md docs/libprism.md docs/configuration.md docs/constructs.md "$stage/$name/docs/"
    cp vendor/libprism/LICENSE.md "$stage/$name/vendor/libprism/"
    tar -czf "dist/$name.tar.gz" -C "$stage" "$name"
    echo "release artifact: dist/$name.tar.gz"
else
    echo "[7/7] packaging skipped (run '$0 package' to create dist/*.tar.gz)"
fi

echo "release check: passed"

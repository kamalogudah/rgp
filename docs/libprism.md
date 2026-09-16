# libprism dependency

RGP vendors the official `ruby/prism` **v1.9.0** `libprism-src.tar.gz`
release artifact in `vendor/libprism`. It is the C99 Ruby parser used by the
deterministic analyzer; RGP does not parse Ruby with regular expressions.

## Pin and provenance

- Upstream repository: <https://github.com/ruby/prism>
- Release tag: `v1.9.0` (published 2026-01-28)
- Release artifact: <https://github.com/ruby/prism/releases/download/v1.9.0/libprism-src.tar.gz>
- SHA-256: `f9002d94f75f1ca66fbaecda7465258d6b1ed3b2b62cba0345617df0ac1c7787`
- License: MIT; the upstream license is retained at `vendor/libprism/LICENSE.md`
  (SHA-256 `b471020939ffa8ec28125e4e31c29ef56dee40aa5403640f8311374cc5b413fc`).

The release artifact contains only the libprism C source, headers, and its
upstream Makefile. `LICENSE.md` is copied verbatim from the same upstream tag.
No Ruby, RubyGems, `make`, system `cc`, or network connection is needed for
RGP's normal build after checkout: Zig compiles the vendored C99 sources.

## Build and verification

`build.zig` creates a target-specific static `prism` library from every C file
in `vendor/libprism/src`, adds its include directory to the RGP module, and
links it into both the CLI and test binary. `src/prism_spike.zig` imports the
real `prism.h` C ABI and calls `pm_parse_success_p` and `pm_version`.

Run the reproducible validation from a checkout:

```sh
zig fmt --check src build.zig
zig build
zig build test
```

The integration test accepts a small Ruby program, rejects malformed Ruby, and
asserts that the linked C library reports `1.9.0`. CI runs those checks on
Linux, macOS, and Windows using the pinned Zig toolchain. The Phase 1 wrapper is exposed as `rgp.prism`: `parse` returns an owning `Document` with copied source and path, a root-node view, and copied diagnostics. Call `Document.deinit` to destroy the tree before its parser and source. Syntax and encoding failures are structured diagnostics rather than crashes or opaque Zig errors.

## Upgrade procedure

1. Select an upstream release tag and download its `libprism-src.tar.gz` from
   the official GitHub release.
2. Verify the archive SHA-256 against the release's published `digest`.
3. Replace the complete `vendor/libprism/include` and `vendor/libprism/src`
   trees, and copy `LICENSE.md` from that exact tag.
4. Update the version, URLs, dates, and hashes in this document; update the
   version assertion in `src/root.zig`.
5. Compare the public C API and build all supported CI targets with `zig build`
   and `zig build test`. Do not change the pin without those passing.

The vendored tree is the source of truth for normal builds. Fetching is only
an explicit maintainer upgrade action; it is never an implicit build step.

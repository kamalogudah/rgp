# ADR-008B — fx runtime integration surface

**Status:** Accepted — ACP process adapter, deferred implementation

**Date:** 2026-09-22

**Scope:** Phase 8 evaluation required by ADR-008 and issue #30. This record evaluates documented process/protocol, interoperability, embedding, and library options in that order.

## Decision

RGP will integrate fx, if and when the adapter is implemented, through the native `fx acp` process boundary using newline-delimited JSON-RPC 2.0 over stdio. RGP will own the `CodingAgent` contract and translate ACP sessions, prompt responses, streamed updates, tool updates, cancellation, capabilities, and errors at `src/agents/fx/adapter.zig`.

No fx runtime dependency is introduced by this decision. The current adapter remains an unavailable boundary placeholder and the offline core remains independent of fx, credentials, and network access.

## Evidence and evaluation

### Tested version and provenance

The reproducible local probe was run with:

```text
fx --version       # fx v0.0.3
zig version        # 0.16.0
```

The probe is captured in `docs/fx-spike.md`. The upstream repository currently requires Zig 0.16.0+ and is Apache-2.0 licensed. The local binary is not treated as a dependency pin: the upstream tag history has advanced beyond v0.0.3, so any implementation must pin a reviewed release and re-run the spike.

### 1. Process and documented protocol — selected

The fx ACP documentation specifies `fx acp` as a stdio server, newline-delimited JSON-RPC 2.0, with `initialize` required before `session/new`/`session/load`/`session/resume`, `session/prompt`, streamed `session/update` events, `session/cancel`, and session close/list operations. It supports chat, streaming, sessions, cancellation, permissions, and tool status/permission updates. Authentication is inherited from the selected fx provider and saved credentials; it is not supplied by RGP.

This is a narrow, observable boundary with no Zig type or build dependency. It also permits RGP to fail clearly when fx is missing, unauthenticated, or protocol-incompatible.

### 2. Interoperability — compatible, but not selected as a second boundary

ACP is the interoperability surface used by editors and other clients. It is the right protocol for this adapter, rather than a private fx wire format. RGP will not implement a separate MCP client-to-fx path: MCP is an fx-side tool integration surface, while RGP's deterministic tools belong behind the RGP adapter contract. Capability discovery must precede use of tool calls, streaming, file access, or permissions.

### 3. Embedding — rejected for this phase

fx documents native and WebAssembly embedding. `libfx` is a JavaScript-host SDK with `prompt`, `checkpoint`, and `close`, host-owned tools and storage, and experimental WebAssembly support. It does not provide the Zig-native, provider-neutral embedding contract RGP needs, and it would introduce a larger host/runtime surface than ACP.

### 4. Direct library/internal dependency — rejected

The fx Zig package currently declares no Zig package dependencies, but direct source/library coupling would still couple RGP to fx's internal API and release cadence. fx describes itself as experimental, and its documented authentication, permissions, tools, session persistence, and provider state are runtime concerns. The ACP process boundary contains those upgrade risks and keeps them out of the offline analyzer.

## Capabilities, authentication, and upgrade risk

The required RGP behavior is chat plus a persistent session, with streamed tool status/events and cancellation. ACP can represent these, but the current normalized `Response` contract does not yet preserve structured tool-call arguments/results. The adapter implementation must extend that contract (or add an event channel) before claiming tool execution support.

fx authentication is provider-specific: the ACP process uses the selected fx provider and saved credentials, including Gateway or configured model connections. RGP must never copy or manage those credentials. A missing or expired credential is an adapter error, not an offline-core error.

Upgrade risk is medium/high because fx is explicitly experimental, the local binary and upstream release line can diverge, and ACP payload capabilities can grow. Mitigations are: pin a reviewed fx release for integration tests, keep the process/protocol translation isolated, validate the ACP initialize capabilities, retain a deterministic fixture spike, and keep offline tests free of fx.

## Validation

- `src/agents/fx/spike.zig` deterministically exercises chat, tool events, session continuity, and cancellation at the RGP boundary without fx.
- `zig build test` compiles and runs the spike and existing offline tests.
- `docs/fx-spike.md` records the installed-version, CLI, ACP launch, and authentication evidence and gives the exact repeatable commands.
- `build.zig.zon` contains no fx dependency; offline analyzer tests therefore do not require fx, a provider credential, or network access.


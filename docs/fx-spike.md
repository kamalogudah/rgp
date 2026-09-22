# fx integration spike

This is the Phase 8 evidence for the runtime-dependency decision. It keeps the protocol observations separate from the offline contract test in `src/agents/fx/spike.zig`.

## Deterministic offline check

Run from the repository root:

```bash
zig build test
```

The `fx protocol-shaped session preserves chat, tool events, and cancellation` test proves the required normalized behavior with a deterministic ACP-shaped event stream. It does not contact a model and does not install or import fx.

## Local fx probe

```bash
fx --version
fx acp --help
fx status --json
```

Evidence captured on 2026-09-22:

```text
fx v0.0.3
fx acp: Start an ACP server over stdio
status: auth is expired (`auth`: `fx login`)
```

The ACP launch probe was:

```bash
printf '%s\n' \
  '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":1,"clientCapabilities":{},"clientInfo":{"name":"rgp-spike","version":"0"}}}' \
  '{"jsonrpc":"2.0","id":2,"method":"session/new","params":{"cwd":"/absolute/path/to/rgp"}}' \
  | fx acp
```

With the local v0.0.3 installation this returned an initialize error, `Failed to load startup state`, followed by the expected protocol error for the second request, `Not initialized. Call initialize first.` The failure is environment/authentication evidence, not a reason to add fx to the build. After authenticating a pinned candidate release, repeat the same probe and then exercise `session/prompt` with a harmless chat request and an RGP tool fixture. The adapter must record the release, ACP capabilities, provider configuration class (never secrets), session id, tool update, and cancel result.

## Source provenance

- fx README: https://github.com/vercel-labs/fx/blob/main/README.md
- fx ACP documentation: https://fx.sh/docs/using-fx/acp
- fx embedding documentation: https://fx.sh/docs/lib
- fx license: https://github.com/vercel-labs/fx/blob/main/LICENSE
- Agent Client Protocol overview: https://github.com/agentclientprotocol/agent-client-protocol/blob/main/docs/protocol/v1/overview.mdx


# Coding-agent adapters

RGP's normalized `CodingAgent` contract lives in `src/agent/contract.zig`.
Analysis, curriculum, exercises, and storage do not import fx types. Adapters
translate sessions, requests, responses, streaming, cancellation, capabilities,
and errors at that boundary.

The registry currently selects `fx` by default. fx is optional and is reported
as unavailable until an adapter process is configured; deterministic RGP
commands continue to work offline.

```text
rgp agent list       # registered adapters and availability
rgp agent status     # selected adapter, default, availability
rgp agent use fx     # validate a process-local selection
rgp ask "Explain ..."
rgp ask --agent fx "Explain ..."
```

`agent use` is process-local in this phase. `ask` never silently falls back:
an unavailable or unknown adapter returns an error and suggests the offline
commands. A future configured adapter must advertise capabilities before RGP
uses streaming, tool calls, file access, or other optional features.


## Gateway permission modes

The RGP gateway owns authorization independently of adapter capabilities. Its
safe default is `learn`:

- `observe` permits read/analyze tools only.
- `learn` permits lessons, exercises, submissions, and learner progress, but
  never repository writes or shells.
- `suggest` is read-only and cannot persist learner mutations.
- `edit` permits repository writes only when the request carries explicit
  approval; it does not permit unrestricted shells.
- `agent` permits approved repository work and is the only mode that may use
  an unrestricted shell.

All repository paths are checked against the configured workspace boundary;
`..` traversal and sibling prefixes are rejected. Cancellation is checked
before tool execution, and exercise submissions are bounded by source, step,
and output limits. These checks are implemented in `src/agent/gateway.zig`
and covered by `zig build test`.

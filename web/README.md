# RGP web UI

This is the initial dependency-free browser client for the Phase 11 navigation
areas: Learn, Explore, Practice, Explain, Corpus, and Progress.

It expects a POST endpoint at `/api/tools` (or `window.RGP_API_ENDPOINT`) that
accepts the documented `rgp.tools.v1` envelope from `docs/api.md` and returns
its JSON response. The client has no parser, classifier, competency, or corpus
logic; those remain in the Zig core and gateway.

Serve this directory with any static file server and provide an API adapter for
the gateway. For an alternate learner, set `window.RGP_LEARNER_ID` before
loading `app.js`.

The reproducible deployment and operations runbook is
[`docs/deployment.md`](../docs/deployment.md).

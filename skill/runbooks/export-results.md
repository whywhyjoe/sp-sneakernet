# export-results (prod, human) — the JSFiddle bridge

The ONLY way data leaves the prod tenant: a human copies a JSON blob from the
harness and pastes it where the dev side can read it.

## Steps

1. Open the project's harness page (`SitePages/_harness-<project>.aspx`).
2. Run the op(s) the agent asked for — **run verify.js**, **run test-smoke.js**,
   or a named suite. Each run also writes a row to the `TestRuns` list.
3. Click **copy results JSON** (appears under the output once the op finishes).
4. Paste the JSON into the agreed JSFiddle (or directly back to the requesting
   agent/chat if that's the ask).

## Notes

- The JSON contains `{suite, passed, results}` plus whatever the op reported
  (drift lists, item counts, errors). Paste it whole — the reader summarizes;
  don't trim or paraphrase it.
- Multiple runs: copy after each run, or read the accumulated rows from the
  TestRuns list view and paste those.
- Nothing automated exports from prod by design — if something seems to need
  automatic egress, that's a design smell to raise, not a gap to work around.

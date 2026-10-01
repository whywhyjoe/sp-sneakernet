# export-results (prod, human) — the JSFiddle bridge

The ONLY way data leaves the prod tenant: a human saves a JSFiddle that the
dev side then reads. `tools/sp/send-to-dev.js` prepares and prefills it; the
human's Ctrl+S is the send.

## Steps

1. Open the project's harness page (`SitePages/_harness-<project>.aspx`).
2. Run the op(s) the agent asked for — **run verify.js**, **run test-smoke.js**,
   or a named suite. Each run also writes a row to the `TestRuns` list.
3. Click **copy results JSON** (appears under the output once the op finishes).
4. In the project checkout: `node tools/sp/send-to-dev.js results` (reads the
   clipboard). It checks the payload and opens JSFiddle **prefilled** —
   nothing is saved yet.
5. In the browser: review the **JavaScript** panel, make sure you're logged in
   to JSFiddle, press **Ctrl+S**, and send dev the URL from the address bar
   (`jsfiddle.net/<user>/<slug>/<n>/`). Saving is the moment data leaves.

**Code changes made on prod** go the same way, never as a commit (prod can't
push): `node tools/sp/send-to-dev.js diff` packs every uncommitted change
including new files; `... files [paths]` packs whole files (default: the whole
repo) — use it for a project's first send, when dev has nothing to diff
against. Then step 5. Once dev has pushed the change: `git stash -u; git pull`.

`send-to-dev.js` refuses to continue on BLOCK findings (values from
`env.local.json`, private keys, secret-looking assignments, tokens) and stops
on WARN findings (SharePoint hosts, email addresses) until a human has looked
and rerun with `--allow-warnings`. Payload line 2 is a `throw`, because the
prefilled editor runs the JS panel automatically. `--dry-run` writes the
payload to the temp folder without opening a browser. The generated
`.github/copilot-instructions.md` tells the prod Copilot to drive all of this.

No `send-to-dev.js` in an older project? Paste by hand: the results JSON, or
`git diff` output, or whole files each headed `// FILE: <repo-relative path>`
— dev's unpacker reads all three.

## Notes

- The JSON contains `{suite, passed, results}` plus whatever the op reported
  (drift lists, item counts, errors). Send it whole — the reader summarizes;
  don't trim or paraphrase it.
- Multiple runs: send after each run, or read the accumulated rows from the
  TestRuns list view and send those.
- Nothing automated exports from prod by design: the script prepares, a human
  reviews and saves. If something seems to need automatic egress, that's a
  design smell to raise, not a gap to work around.

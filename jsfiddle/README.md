# jsfiddle/ — JSFiddle bridge tooling

Stdlib-only Python CLIs for the JSFiddle side of the prod→dev bridge (see the repo
README's "JSFiddle bridge" glossary entry). No pip installs, no browser automation —
plain HTTP against jsfiddle.net's server-rendered pages and private XHR endpoints.

| File | Purpose |
| --- | --- |
| `jsfiddle-fetch.py` | Read side. Fetch a fiddle's HTML/CSS/JS panels + metadata (no auth for public fiddles), optionally the compiled `/show/` page, or `--list USER` to enumerate a user's fiddles. |
| `jsfiddle-push.py` | Write side. `create` a new fiddle or `update` an existing one (makes a new version). Needs a logged-in session cookie via `--cookie-file` or `JSFIDDLE_COOKIE` — see the script's docstring for the one-time setup. |
| `jsfiddle-backend-http-access.md` | Reverse-engineering notes: every endpoint used, auth/CSRF details, what was live-verified and when. |

Typical bridge round trip:

```bash
python jsfiddle-fetch.py https://jsfiddle.net/<user>/<slug>/ -o fiddle_out
```

```bash
python jsfiddle-push.py update <slug> --js app.js --cookie-file _secrets/jsf_cookie.txt
```

Dev agents find this folder through `localRepos.sneakernet` in the sp-env
`tenants.local.json`; the procedure is the sp-env runbook
[`import-from-jsfiddle`](../skill/runbooks/import-from-jsfiddle.md).

Status (2026-10-01): JSFiddle moved its editor to a client-rendered page that embeds
the fiddle as JSON (`<script id="editor-bootstrap">`) instead of form textareas.
`jsfiddle-fetch.py` was updated and re-verified against public fiddles.
`jsfiddle-push.py` was **not** — it scrapes the old server-rendered form fields, which
the new page no longer has, so expect it to fail until the save requests are
re-captured in DevTools (logged in) and the notes file and script updated.

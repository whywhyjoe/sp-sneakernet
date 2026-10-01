# jsfiddle/ — JSFiddle bridge tooling

Stdlib-only Python CLIs for the JSFiddle side of the prod→dev bridge (see the repo
README's "JSFiddle bridge" glossary entry). No pip installs, no browser automation —
plain HTTP against jsfiddle.net's editor pages (embedded bootstrap JSON) and private XHR endpoints.

| File | Purpose |
| --- | --- |
| `jsfiddle-fetch.py` | Read side. Fetch a fiddle's HTML/CSS/JS panels + metadata (no auth for public fiddles). A URL without a version resolves to the newest version saved by the URL's user (an unversioned page is the *base* version, and other accounts can save versions under your slug — those are refused). Optionally the compiled `/show/` page, or `--list USER` to enumerate a user's fiddles. |
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
the fiddle as JSON (`<script id="editor-bootstrap">`). Both scripts were rebuilt on it:
fetch is verified end to end; push's request format was captured from the live editor
and verified by updating a test fiddle from a logged-in page, but the script itself
has not yet been run with a real cookie file. Cookie setup is in the push script's
docstring; keep the file in `_secrets/` (gitignored).

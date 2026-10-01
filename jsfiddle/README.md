# jsfiddle/ — JSFiddle bridge tooling

Stdlib-only Python CLIs for the JSFiddle side of the prod→dev bridge (see the repo
README's "JSFiddle bridge" glossary entry). No pip installs, no browser automation —
plain HTTP against jsfiddle.net's editor pages (embedded bootstrap JSON) and private XHR endpoints.

| File | Purpose |
| --- | --- |
| `jsfiddle-fetch.py` | Read side. Fetch a fiddle's HTML/CSS/JS panels + metadata (no auth for public fiddles). A URL without a version resolves to the newest version saved by the URL's user (an unversioned page is the *base* version, and other accounts can save versions under your slug — those are refused). Optionally the compiled `/show/` page, or `--list USER` to enumerate a user's fiddles. |
| `jsfiddle-push.py` | Write side. `create` a new fiddle or `update` an existing one (makes a new version). Gets the login session from `jsfiddle-session.js` automatically (or `--cookie-file` / `JSFIDDLE_COOKIE` as overrides). |
| `jsfiddle-session.js` | JSFiddle login kept in a Playwright Edge profile (`_secrets/jsfiddle-profile`, gitignored). `login` opens Edge once for you to sign in; `status` checks it headless; `cookie` is for the push script only. Uses the sp-env skill's Playwright. |
| `jsfiddle-backend-http-access.md` | Reverse-engineering notes: every endpoint used, auth/CSRF details, what was live-verified and when. |

Typical bridge round trip:

```bash
python jsfiddle-fetch.py https://jsfiddle.net/<user>/<slug>/ -o fiddle_out
```

```bash
python jsfiddle-push.py update https://jsfiddle.net/<user>/<slug>/ --js app.js
```

Dev agents find this folder through `localRepos.sneakernet` in the sp-env
`tenants.local.json`; the procedure is the sp-env runbook
[`import-from-jsfiddle`](../skill/runbooks/import-from-jsfiddle.md).

Status (2026-10-01): JSFiddle moved its editor to a client-rendered page that embeds
the fiddle as JSON (`<script id="editor-bootstrap">`). Both scripts were rebuilt on it:
fetch is verified end to end; push's request format was captured from the live editor
and verified by updating a test fiddle from a logged-in page. The first push from the
script opens Edge for a one-time JSFiddle login (the profile is then reused headless);
that first end-to-end run is still pending.

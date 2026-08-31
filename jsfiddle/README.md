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
python jsfiddle-fetch.py https://jsfiddle.net/Jzapert1/snxczjv5/ -o fiddle_out
```

```bash
python jsfiddle-push.py update snxczjv5 --js app.js --cookie-file _secrets/jsf_cookie.txt
```

Caveat: the write endpoints (`/_save/`, `/_update/`) and the form-field whitelist are
a snapshot of JSFiddle's private editor API, captured and verified 2026-07-18. If
pushes start failing, re-capture the requests in DevTools and diff against the notes
file before debugging the scripts.

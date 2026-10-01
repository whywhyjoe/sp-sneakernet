# jsfiddle/ — JSFiddle bridge tooling

Stdlib-only Python CLIs for the JSFiddle side of the prod→dev bridge (see the repo
README's "JSFiddle bridge" glossary entry). No pip installs — plain HTTP against
jsfiddle.net's editor pages (embedded bootstrap JSON) and private XHR endpoints. The
one exception is the JSFiddle login, which lives in a Playwright Edge profile: push
always uses it, and fetch uses it only for **private** fiddles.

| File | Purpose |
| --- | --- |
| `jsfiddle-fetch.py` | Read side. Fetch a fiddle's HTML/CSS/JS panels + metadata (no auth for public fiddles). A **private** fiddle answers every anonymous request with HTTP 500, so on a 500/404 fetch falls back to a signed-in read through `jsfiddle-session.js` automatically (`--signed-in` forces it; `--anon-only` turns it off). `fiddle.json` records `private` and `read` (`anonymous` / `signed-in`). A URL without a version resolves to the newest version saved by the URL's user (an unversioned page is the *base* version, and other accounts can save versions under your slug — those are refused). Optionally the compiled `/show/` page, or `--list USER` to enumerate a user's fiddles. |
| `jsfiddle-unpack.py` | Turns a fetched sneakernet fiddle (from prod's `tools/sp/send-to-dev.js`, or a hand paste) back into what it carries: **files** rebuilt byte-exact and sha256-verified, a **diff** checked and `git apply`ed, or **results** saved and summarized. `--into <repo>`, `--dry-run`, `--force`. |
| `jsfiddle-push.py` | Write side. `create` a new fiddle or `update` an existing one (makes a new version). Gets the login session from `jsfiddle-session.js` automatically (or `--cookie-file` / `JSFIDDLE_COOKIE` as overrides). |
| `jsfiddle-session.js` | JSFiddle login kept in a Playwright Edge profile (`_secrets/jsfiddle-profile`, gitignored). `login` opens Edge once for you to sign in; `status` checks it headless; `read <url>` / `versions <url>` are fetch's signed-in read for private fiddles. They print only code and metadata, never the cookie or CSRF token. `cookie` is for the push script only; never run it yourself. Only one process can use the profile at a time: a second one exits 7 ("profile busy"). Uses the sp-env skill's Playwright. |
| `jsfiddle-backend-http-access.md` | Reverse-engineering notes: every endpoint used, auth/CSRF details, what was live-verified and when. |

Typical bridge round trip — prod runs `node tools/sp/send-to-dev.js files|diff|results`
(prefills JSFiddle; the human reviews and saves), then dev:

```bash
python jsfiddle-fetch.py https://jsfiddle.net/<user>/<slug>/ -o fiddle_out
```

```bash
python jsfiddle-unpack.py fiddle_out --into <project repo> --dry-run
```

```bash
python jsfiddle-push.py update https://jsfiddle.net/<user>/<slug>/ --js app.js
```

Dev agents find this folder through `localRepos.sneakernet` in the sp-env
`tenants.local.json`; the procedures are the sp-env runbooks
[`import-from-jsfiddle`](../skill/runbooks/import-from-jsfiddle.md) (read) and
[`push-to-jsfiddle`](../skill/runbooks/push-to-jsfiddle.md) (write).

Private fiddles (2026-10-01): verified by fetching private `Jzapert1/y91jLw26` v1 and its
unversioned URL (resolved signed in to the newest version).

Status (2026-10-01): JSFiddle moved its editor to a client-rendered page that embeds
the fiddle as JSON (`<script id="editor-bootstrap">`). Both scripts were rebuilt on it:
both verified end to end (push created v3 of test fiddle `Jzapert1/zrsbv5nf` via the
Edge-profile login; fetch read it back as the newest version by Jzapert1). The first
push opens Edge for a one-time JSFiddle login; the profile is then reused headless.

# JSFiddle backend HTTP access — findings (first verified 2026-07-18; re-captured 2026-10-01)

Goal: pull/push fiddle code programmatically (no front-end automation) for the home↔work pipeline.

**2026-10-01:** the editor is now a Vite client app. The server no longer renders the
form; everything the editor needs is in one embedded JSON blob:

```
<script type="application/json" id="editor-bootstrap">{"config": {...}, "i18n": ..., "settings": ...}</script>
```

| `config.` key | Holds |
| --- | --- |
| `value` | `{html, css, js}` — exact panel sources (plain JSON strings) |
| `fiddle` | `{slug, version, pastie_id, private, boilerplate}` — the version actually served |
| `header` | `{title, description, expirationDays, author, ...}` |
| `panelOptions.values` | `{doctype, jsLib, jsLibOption, bodyTag, normalizeCss}` |
| `languages.current` | `{html, css, js}` each `{id, name}` — the panel language ids |
| `session` | `{signedIn, user, csrfToken, ...}` — csrfToken (86 chars) is present even logged out |
| `paths` | `save: /_save/`, `update: /_update/{slug}/` (null when not yours), `fork: /_fork/`, `saveSettings`, `customPage`, `fiddlePrivacy`, ... |

## READ

### 1. Panel source
`GET https://jsfiddle.net/{user}/{slug}/{version}/` — plain unauthenticated GET works for
public fiddles. Parse the bootstrap JSON; `config.value` is the code.

**Private fiddles (verified 2026-10-01, `Jzapert1/y91jLw26`, `config.fiddle.private = true`):**
an anonymous request gets **HTTP 500** ("Oops. This shouldn't have happened") for the
editor page, both slug-only and `/{user}/{slug}/` with or without a version. It also
gets 500 for version numbers that don't exist, so anonymous version probing never reaches
a 404. `/show/` is **404**, and the fiddle is **absent from list.json**. A signed-in
request through the owner's profile works normally: 200 for saved versions, 404 past the
newest, 3xx for another account's version. A plain `context.request.get` from the
Playwright persistent context is enough; no page render is needed, so the fiddle's
code never runs. `jsfiddle-session.js read` / `versions` do exactly this, and
`jsfiddle-fetch.py` falls back to them on 500/404.

What the signed-in bootstrap holds that must **not** be printed:
- `config.session.csrfToken` and the account details under `config.session`.
- `config.paths.render`, which is `//fiddle.jshell.net/{user}/{slug}/{n}/show/?token=…`: a
  signed Rails token, valid ~1 hour, that opens the private `/show/` page.

`read` therefore prints only `{config: {value, fiddle, header: {title, author}}}`.
`header.author` is `{initials, tooltip, interactive}`, not a username. The author check is
the redirect check (`maxRedirects: 0`). Fetch skips `--show` for private fiddles.

*Until mid-2026* the page was server-rendered with the code in
`<textarea name="code_html|code_css|code_js">` (HTML-entity-encoded). `jsfiddle-fetch.py`
still accepts that layout as a fallback.

### 2. Versions — two traps (verified 2026-10-01)
- **An unversioned URL is NOT the latest.** It serves the fiddle's *base* version
  (`config.fiddle.version`; 0 for a fiddle saved then updated with Ctrl+S — the test
  fiddle served v0 while v2 existed). Always read an explicit version.
- **Other accounts can save versions under your slug.** `GET /{user}/{slug}/{n}/` returns
  **200** when version n was saved by `{user}`, **302** to `/{otheruser}/{slug}/{n}/` (or
  `/{slug}/{n}/` for anonymous) when someone else saved it, **404** when it doesn't exist.
  Example: `macloo/bvwvd0ao` base is v26, `latest_version` is 1108, and 27..1108 all
  redirect to other users. So "newest" must mean newest *by the expected user* — check
  with redirects disabled. `jsfiddle-fetch.py` does this and refuses other authors.

### 3. Compiled result page
`GET https://fiddle.jshell.net/{user}/{slug}/{version}/show/` → single combined HTML page.
**403 without a Referer header** (verified). Send `Referer: https://fiddle.jshell.net/{path}/show/`.

### 4. Enumerate a user's fiddles
`GET https://jsfiddle.net/api/user/{user}/demo/list.json?sort=date&start=0&limit=100`
JSON array; fields: `framework, version, description, title, url, author, latest_version, created`.
Paginate with `start`. Public fiddles only (private ones are simply missing). `version` = base version; `latest_version` =
highest version number under the slug, **whoever saved it** (see trap above).

### Download
The new editor has `/{slug}/{version}/download` (loaded in a hidden iframe by the Download
button). Not used by the scripts — the panels are enough.

## WRITE (captured live from the editor 2026-10-01, account Jzapert1)

- **Create:** `POST https://jsfiddle.net/_save/`
- **Update:** `PATCH https://jsfiddle.net/_update/{slug}/` → creates a **new version**
- Body: **multipart/form-data** (the editor posts `new FormData(form)`), fields in order:
  `authenticity_token, expiration_days, description, title, code_html, code_css, code_js,
  panel_html, doctype, body_tag, panel_js, js_lib, js_lib_option, panel_css`
  (gone since July: `username, mistral_api_key, q, modalTopMenu, normalize_css`).
- Headers: `X-CSRF-Token: <config.session.csrfToken>`, `Accept: application/json, text/plain, */*`,
  plus the logged-in session cookie (HttpOnly — not visible to `document.cookie`, which
  shows only `csrftoken` and `JSFIDDLE_theme`).
- Reply (JSON, 200): `{fiddle_path, update_path, slug, version, is_author, pastie_id, title, private, boilerplate}`.
- Rebuilding the form from the bootstrap JSON (no editor involved) is accepted by the
  server: verified by PATCHing test fiddle `Jzapert1/zrsbv5nf` v1 → v2 from a logged-in
  page with a form built purely from `config.*` — the same mapping `jsfiddle-push.py` uses:

  | field | from |
  | --- | --- |
  | `authenticity_token` | `session.csrfToken` |
  | `expiration_days` | `header.expirationDays` (null → `""`) |
  | `title`, `description` | `header.title`, `header.description` |
  | `code_html/css/js` | `value.html/css/js` |
  | `panel_html/css/js` | `languages.current.{html,css,js}.id` |
  | `doctype`, `js_lib`, `js_lib_option`, `body_tag` | `panelOptions.values.doctype/jsLib/jsLibOption/bodyTag` |

- `expiration_days` empty = keep forever; `1`, `10`, `30` etc. auto-expire the fiddle
  (verified: `header.expirationDays` reads back 1).

### Prefill API (no auth, nothing saved) — what prod's send-to-dev.js uses
`POST https://jsfiddle.net/api/post/{framework}/{version}/` (we use `library/pure`) with
fields `html, css, js, title, description, resources...` opens an editor prefilled with
your code (docs.jsfiddle.net); the human then saves. Verified 2026-10-01:
- Text is kept exactly (incl. `//` lines); a 3 MB `js` field round-tripped intact.
- A browser form POST turns the textarea's newlines into CRLF — consumers must
  LF-normalize (jsfiddle-unpack.py does; its hashes are over LF text).
- **The prefilled editor has `bootstrap.autorun: true`** — the JS panel runs on open.
  send-to-dev.js makes payload line 2 a `throw`, so nothing in it can execute.
- Ctrl+S while logged in saves via the normal `/_save/` under **the logged-in account**
  (`/Jzapert1/9o5231pd/`), so fetch's author check works on prefilled saves.
- The editor opens on the HTML tab; the payload is in the JavaScript tab.

## Scripts (stdlib-only Python 3.10+)
- `jsfiddle-fetch.py` — read side: bootstrap-JSON panels + metadata; unversioned URL →
  newest version saved by the URL's user; refuses another account's version; `--show`
  compiled page; `--list USER`.
- `jsfiddle-push.py` — write side: `create` / `update` with `--html/--css/--js` files or
  inline code, `--title`, `--description`, `--expire`; session from `jsfiddle-session.js`
  (overrides: `--cookie-file`, `JSFIDDLE_COOKIE`). Flow: GET editor page with cookie → bootstrap JSON → rebuild form →
  override → multipart POST/PATCH with `X-CSRF-Token`.

- `jsfiddle-unpack.py` — dev side of prod's `send-to-dev.js` payloads (`// SNEAKERNET`
  header, `throw` guard, `// FILE: {path, sha256, eol, finalNewline}` blocks; marker-like
  content lines are escaped with one extra leading backslash).
- `jsfiddle-session.js` — Playwright persistent profile (`_secrets/jsfiddle-profile`,
  installed Edge via `channel: 'msedge'`, bundled Chromium fallback). Signed-in check =
  `context.request.get('/')` → bootstrap `config.session.signedIn`; the session cookie is
  HttpOnly, so it is read with `context.cookies()`, never `document.cookie`.
  `read <url>` / `versions <url>`: signed-in read side for private fiddles (above).
  **One process at a time:** a running browser holds `<profile>/lockfile` open (EBUSY on
  Windows). A second Edge on the same profile just hands off to the first one, and
  Playwright then reports a generic "Target page, context or browser has been closed".
  The script therefore checks the lockfile before launching and exits 7 ("profile
  busy"). It falls back to bundled Chromium only when Edge is not installed: Chromium on
  the Edge profile looks signed out.

## Prior art
github.com/facundovictor/jsfiddle-downloader (npm 0.2.2) — read-only, uses the /show/ + list.json endpoints.

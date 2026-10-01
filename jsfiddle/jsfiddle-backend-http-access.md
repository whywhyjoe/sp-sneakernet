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
Paginate with `start`. Public fiddles only. `version` = base version; `latest_version` =
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

### Sidenote: prefill-only API (no auth, nothing saved)
`POST https://jsfiddle.net/api/post/{framework}/{version}/` with fields `html, css, js, title, description, resources...` opens an editor prefilled with your code (docs.jsfiddle.net). Useful for "open my local code in a fiddle" without touching the account; the user then saves manually.

## Scripts (stdlib-only Python 3.10+)
- `jsfiddle-fetch.py` — read side: bootstrap-JSON panels + metadata; unversioned URL →
  newest version saved by the URL's user; refuses another account's version; `--show`
  compiled page; `--list USER`.
- `jsfiddle-push.py` — write side: `create` / `update` with `--html/--css/--js` files or
  inline code, `--title`, `--description`, `--expire`; session from `jsfiddle-session.js`
  (overrides: `--cookie-file`, `JSFIDDLE_COOKIE`). Flow: GET editor page with cookie → bootstrap JSON → rebuild form →
  override → multipart POST/PATCH with `X-CSRF-Token`.

- `jsfiddle-session.js` — Playwright persistent profile (`_secrets/jsfiddle-profile`,
  installed Edge via `channel: 'msedge'`, bundled Chromium fallback). Signed-in check =
  `context.request.get('/')` → bootstrap `config.session.signedIn`; the session cookie is
  HttpOnly, so it is read with `context.cookies()`, never `document.cookie`.

## Prior art
github.com/facundovictor/jsfiddle-downloader (npm 0.2.2) — read-only, uses the /show/ + list.json endpoints.

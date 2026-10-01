# JSFiddle backend HTTP access — findings (verified 2026-07-18)
 
Goal: pull/push fiddle code programmatically (no front-end automation) for the home↔work pipeline.
 
## READ
 
### 1. Panel source — the recommended method
`GET https://jsfiddle.net/{user}/{slug}/{version}/` (plain unauthenticated GET works for public fiddles; omit version for latest).

**Update 2026-10-01 (verified):** the editor is now a Vite client app. The page embeds
`<script type="application/json" id="editor-bootstrap">`; parse it and read
`config.value` = `{html, css, js}` (exact panel sources, plain JSON strings) and
`config.fiddle` = `{slug, version, pastie_id, private, ...}` (version = what "latest"
resolved to). There are **no** `code_*` textareas and almost no `<input>`s any more —
which also means the WRITE flow below (scrape form fields + `authenticity_token` from
the page) is stale until re-captured. The textarea layout below is kept as history /
fallback.

*Previous layout (until mid-2026):* the editor page was **server-rendered** and contained the code in three textareas:
 
- `name="code_html"` / `id="textarea-code-html"`
- `name="code_css"` / `id="textarea-code-css"`
- `name="code_js"` / `id="textarea-code-js"`
Contents are HTML-entity-encoded (`&lt;` etc.) — decode with `html.unescape()`. Title is in `<title>`. Verified against the TestFiddle.
 
### 2. Compiled result page
`GET https://fiddle.jshell.net/{user}/{slug}/{version}/show/` → single combined HTML page.
**403 without a Referer header** (verified). Send `Referer: https://fiddle.jshell.net/{path}/show/`.
 
### 3. Enumerate a user's fiddles
`GET https://jsfiddle.net/api/user/{user}/demo/list.json?sort=date&start=0&limit=100`
JSON array; fields: `framework, version, description, title, url, author, latest_version, created`. Paginate with `start`. Verified 200.
 
### No backend ZIP export
The top-bar "Download fiddle" button is **client-side only** (builds the file in the browser JS; no download URL exists in the app bundle or endpoint config). Reconstruct files from the panels instead.
 
## WRITE (captured live from real editor requests, 2026-07-18)
 
- **Create new fiddle:** `POST https://jsfiddle.net/_save/` → responds with new fiddle path (verified: created `a2y4nj0s`, 1-day expiry).
- **Update existing:** `PATCH https://jsfiddle.net/_update/{slug}/` → creates a **new version** (verified: TestFiddle v1 → v3). 200 on success.
- Also in the editor endpoint config: `fork: /_fork/`, `saveSettings: /_editor_options/`, `add resource: /_add_external_resource/`.
Payload = urlencoded/XHR form fields (whitelist captured from a real save):
`username, authenticity_token, expiration_days, description, title, mistral_api_key, q, modalTopMenu, panel_html, doctype, body_tag, panel_js, js_lib, js_lib_option, panel_css, code_html, code_css, code_js`
 
Auth requirements:
- **Session cookie** (HttpOnly — copy from DevTools; site is Django: `csrftoken` + session cookie).
- **`authenticity_token`** — hidden `<input>` (86 chars) in any server-rendered editor page; GET the page with your cookie and parse it out. Send it in the form body (plus `X-CSRFToken: <csrftoken cookie>` and a jsfiddle.net `Referer` for Django CSRF).
- `expiration_days` empty = keep forever; values like `1`, `10`, `30` etc. auto-expire the fiddle.
### Sidenote: prefill-only API (no auth, nothing saved)
`POST https://jsfiddle.net/api/post/{framework}/{version}/` with fields `html, css, js, title, description, resources...` opens an editor prefilled with your code (docs.jsfiddle.net). Useful for "open my local code in a fiddle" without touching the account; the user then saves manually.
 
## Scripts (delivered 2026-07-18 session, stdlib-only Python)
- `jsfiddle-fetch.py` — read side: fetch panels + metadata, `--show` compiled page, `--list USER`.
- `jsfiddle-push.py` — write side: `create` / `update` with `--html/--css/--js` files or inline code, `--title`, `--expire`, cookie via `--cookie-file` or `JSFIDDLE_COOKIE`. Flow: GET editor page → parse all form fields (keeps existing settings) → override panels → POST/PATCH.
## Prior art
github.com/facundovictor/jsfiddle-downloader (npm 0.2.2) — read-only, uses the /show/ + list.json endpoints.
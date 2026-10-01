#!/usr/bin/env python3
"""
jsfiddle-push.py — create a new JSFiddle or push new code to an existing one,
using plain HTTP requests (no browser automation).

How it works (captured live from the editor 2026-10-01; first version 2026-07-18):
  * CREATE:  POST  https://jsfiddle.net/_save/
  * UPDATE:  PATCH https://jsfiddle.net/_update/{slug}/      -> creates a NEW VERSION
  * FORK:    POST  https://jsfiddle.net/_fork/               (not implemented here)
  Both are multipart/form-data XHRs carrying the editor's form fields (FIELDS
  below), with the CSRF token sent twice: as the `authenticity_token` field and
  as the `X-CSRF-Token` header. The JSON reply carries fiddle_path, slug and
  version.
  The editor page is client-rendered: everything the form is built from lives
  in the embedded <script type="application/json" id="editor-bootstrap">
  (config.session.csrfToken, config.value, config.header, config.panelOptions,
  config.languages.current). The flow this script uses:
    1. GET the editor page (the fiddle URL for update, jsfiddle.net/ for create)
       with your Cookie header, and parse the bootstrap JSON.
    2. Rebuild the form from it — this preserves the fiddle's existing settings
       (title, description, expiry, doctype, JS library, panel languages).
    3. Override the code panels / title / description / expiry with your input.
    4. POST or PATCH the form back.

Auth (default: no manual cookie handling):
  The session comes from a dedicated Playwright browser profile managed by
  jsfiddle-session.js (in _secrets/jsfiddle-profile, gitignored). The first
  run - or any run after the JSFiddle session expires - opens Edge on the
  login page and waits for you to log in once; after that pushes are fully
  headless. The cookie is held in memory only. Needs Node + Playwright (the
  sp-env skill's copy is used if this folder has none).
  Overrides: --cookie-file FILE or JSFIDDLE_COOKIE (a full `Cookie:` header
  value copied from DevTools); --no-login fails instead of opening a browser.
  NOTE: the session cookie is a real credential. Treat it like a password.
 
Usage:
  # update existing fiddle (creates a new version):
  python jsfiddle-push.py update https://jsfiddle.net/<user>/<slug>/ \
      --js app.js --css style.css --html index.html

  # create a brand-new fiddle (--expire 1 for a throwaway):
  python jsfiddle-push.py create --title "My fiddle" --js app.js

  # inline code instead of files:
  python jsfiddle-push.py update <slug> --js-code "console.log('hi')" ...

Stdlib only (urllib). Python 3.10+.
"""

import argparse
import json
import os
import re
import subprocess
import sys
import urllib.error
import urllib.request
import uuid
from pathlib import Path

BASE = "https://jsfiddle.net"
UA = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) fiddle-pipeline/1.0"

# The editor's form, in the order the browser sends it (captured 2026-10-01).
FIELDS = [
    "authenticity_token", "expiration_days", "description", "title",
    "code_html", "code_css", "code_js", "panel_html", "doctype", "body_tag",
    "panel_js", "js_lib", "js_lib_option", "panel_css",
]


SESSION_JS = Path(__file__).with_name("jsfiddle-session.js")
 
 
def session_cookie(allow_login: bool) -> str:
    """Cookie header from the Playwright profile; opens a headed login if needed."""
    def run(cmd, capture):
        return subprocess.run(["node", str(SESSION_JS), cmd], text=True,
                              stdout=subprocess.PIPE if capture else None)
    try:
        r = run("cookie", True)
    except FileNotFoundError:
        sys.exit("node not found - install Node.js, or pass --cookie-file / JSFIDDLE_COOKIE.")
    if r.returncode == 3 and allow_login:
        print("JSFiddle session missing or expired - opening a browser to log in...", file=sys.stderr)
        if run("login", False).returncode != 0:
            sys.exit("JSFiddle login did not complete.")
        r = run("cookie", True)
    if r.returncode == 7:
        sys.exit("The JSFiddle browser profile is busy (another login/push/fetch is using it); retry when it finishes.")
    if r.returncode != 0 or not r.stdout.strip():
        sys.exit(f"Could not get a JSFiddle session (jsfiddle-session.js cookie exit {r.returncode}).")
    return r.stdout.strip()
 
 
def multipart(fields: dict) -> tuple[bytes, str]:
    boundary = "----fiddlepipeline" + uuid.uuid4().hex
    out = []
    for name, value in fields.items():
        out.append(f"--{boundary}\r\n"
                   f'Content-Disposition: form-data; name="{name}"\r\n\r\n'
                   f"{value}\r\n")
    out.append(f"--{boundary}--\r\n")
    return "".join(out).encode("utf-8"), f"multipart/form-data; boundary={boundary}"


def http(url, cookie, method="GET", fields=None, csrf=None, referer=None):
    headers = {"User-Agent": UA, "Cookie": cookie, "Referer": referer or url}
    data = None
    if fields is not None:
        data, headers["Content-Type"] = multipart(fields)
        headers.update({"Accept": "application/json, text/plain, */*",
                        "Origin": BASE, "X-CSRF-Token": csrf})
    req = urllib.request.Request(url, data=data, headers=headers, method=method)
    try:
        with urllib.request.urlopen(req, timeout=30) as resp:
            return resp.status, resp.read().decode("utf-8", errors="replace")
    except urllib.error.HTTPError as e:
        return e.code, e.read().decode("utf-8", errors="replace")


def read_bootstrap(page: str) -> dict:
    m = re.search(r'<script[^>]*id="editor-bootstrap"[^>]*>(.*?)</script>', page, re.DOTALL)
    if not m:
        sys.exit("error: no editor-bootstrap JSON in the editor page. JSFiddle's page "
                 "layout has probably changed; see jsfiddle-backend-http-access.md.")
    return json.loads(m.group(1))["config"]


def form_from_bootstrap(cfg: dict) -> dict:
    """Rebuild the editor form exactly as the client app fills it."""
    value, header = cfg.get("value") or {}, cfg.get("header") or {}
    opts = (cfg.get("panelOptions") or {}).get("values") or {}
    langs = (cfg.get("languages") or {}).get("current") or {}
    lang_id = lambda k: str((langs.get(k) or {}).get("id", 0))
    none_blank = lambda v: "" if v is None else str(v)
    return {
        "authenticity_token": (cfg.get("session") or {}).get("csrfToken") or "",
        "expiration_days": none_blank(header.get("expirationDays")),
        "description": header.get("description") or "",
        "title": header.get("title") or "",
        "code_html": value.get("html") or "",
        "code_css": value.get("css") or "",
        "code_js": value.get("js") or "",
        "panel_html": lang_id("html"),
        "doctype": none_blank(opts.get("doctype")),
        "body_tag": opts.get("bodyTag") or "",
        "panel_js": lang_id("js"),
        "js_lib": none_blank(opts.get("jsLib")),
        "js_lib_option": none_blank(opts.get("jsLibOption")),
        "panel_css": lang_id("css"),
    }


def parse_target(target: str):
    """URL or slug -> (editor page URL, slug)."""
    m = re.search(r"jsfiddle\.net/(?:([\w.-]+)/)?(\w+)(?:/(\d+))?/?", target)
    if m:
        path = "/".join(p for p in m.groups() if p)
        return f"{BASE}/{path}/", m.group(2)
    slug = target.strip("/").split("/")[0]
    return f"{BASE}/{slug}/", slug


def load_panel(file_arg, code_arg):
    if code_arg is not None:
        return code_arg
    if file_arg:
        return Path(file_arg).read_text(encoding="utf-8")
    return None  # keep existing


def main():
    ap = argparse.ArgumentParser(description="Create or update a JSFiddle over HTTP")
    ap.add_argument("action", choices=["create", "update"])
    ap.add_argument("target", nargs="?", help="fiddle URL or slug (required for update)")
    ap.add_argument("--html", help="file with HTML panel content")
    ap.add_argument("--css", help="file with CSS panel content")
    ap.add_argument("--js", help="file with JS panel content")
    ap.add_argument("--html-code", help="inline HTML panel content")
    ap.add_argument("--css-code", help="inline CSS panel content")
    ap.add_argument("--js-code", help="inline JS panel content")
    ap.add_argument("--title")
    ap.add_argument("--description")
    ap.add_argument("--expire", help="expiration_days value (e.g. 1); '' = keep forever")
    ap.add_argument("--cookie-file", help="file containing the Cookie header string "
                    "(default: the jsfiddle-session.js browser profile)")
    ap.add_argument("--no-login", action="store_true",
                    help="never open a browser to log in; fail if the profile session is stale")
    args = ap.parse_args()

    cookie = os.environ.get("JSFIDDLE_COOKIE", "")
    if args.cookie_file:
        cookie = Path(args.cookie_file).read_text(encoding="utf-8").strip()
    if not cookie:
        cookie = session_cookie(allow_login=not args.no_login)

    if args.action == "update":
        if not args.target:
            sys.exit("update requires a fiddle URL or slug")
        page_url, slug = parse_target(args.target)
        endpoint, method = f"{BASE}/_update/{slug}/", "PATCH"
    else:
        page_url = BASE + "/"
        endpoint, method = f"{BASE}/_save/", "POST"

    # 1. GET editor page, parse the bootstrap JSON
    status, page = http(page_url, cookie)
    if status != 200:
        sys.exit(f"GET {page_url} -> {status}")
    cfg = read_bootstrap(page)
    session = cfg.get("session") or {}
    if not session.get("signedIn") or not session.get("csrfToken"):
        sys.exit("Not signed in according to the editor page - the cookie is missing, "
                 "expired, or lacks the session cookie. With the default profile: "
                 "node jsfiddle-session.js login")
    if method == "PATCH" and (cfg.get("paths") or {}).get("update") != f"/_update/{slug}/":
        sys.exit(f"The editor page offers no update path for '{slug}' - not your fiddle, "
                 "or the slug is wrong.")

    # 2-3. Rebuild the form, apply overrides
    fields = form_from_bootstrap(cfg)
    for key, fa, ca in (("code_html", args.html, args.html_code),
                        ("code_css", args.css, args.css_code),
                        ("code_js", args.js, args.js_code)):
        val = load_panel(fa, ca)
        if val is not None:
            fields[key] = val
    if args.title is not None:
        fields["title"] = args.title
    if args.description is not None:
        fields["description"] = args.description
    if args.expire is not None:
        fields["expiration_days"] = args.expire

    # 4. Send
    status, body = http(endpoint, cookie, method=method,
                        fields={k: fields[k] for k in FIELDS},
                        csrf=fields["authenticity_token"], referer=page_url)
    print(f"{method} {endpoint} -> {status}")
    try:
        reply = json.loads(body)
    except ValueError:
        print(body[:400] + ("..." if len(body) > 400 else ""))
        sys.exit(1)
    print(json.dumps(reply, indent=2)[:800])
    if status != 200 or "fiddle_path" not in reply:
        sys.exit(1)
    print(f"fiddle: {BASE}{reply['fiddle_path']}")


if __name__ == "__main__":
    main()

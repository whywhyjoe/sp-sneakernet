#!/usr/bin/env python3
"""
jsfiddle-push.py — create a new JSFiddle or push new code to an existing one,
using plain HTTP requests (no browser automation).
 
How it works (endpoints captured live from the editor, July 2026):
  * CREATE:  POST  https://jsfiddle.net/_save/
  * UPDATE:  PATCH https://jsfiddle.net/_update/{slug}/      -> creates a NEW VERSION
  * FORK:    POST  https://jsfiddle.net/_fork/               (not implemented here)
  Both requests are ordinary form posts (XHR) whose fields mirror the editor's
  form. The server requires:
    - your logged-in session cookie   (HttpOnly; copy it from your browser)
    - authenticity_token              (CSRF; embedded as a hidden <input> in any
                                       server-rendered editor page, so we GET the
                                       page first and parse it out)
  The flow this script uses:
    1. GET the editor page (the fiddle URL for update, jsfiddle.net/ for create)
       with your Cookie header.
    2. Parse ALL form fields out of the server-rendered HTML (inputs, checked
       radios, textareas, selected options) — this preserves the fiddle's
       existing settings (doctype, JS library, panels, title...).
    3. Override the code panels / title / description with your new content.
    4. POST or PATCH the whitelisted field set back.
 
Auth setup (one time per session):
  In Chrome on jsfiddle.net (logged in): DevTools > Application > Cookies >
  https://jsfiddle.net — copy the cookies into a single header string, e.g.:
      csrftoken=...; sessionid=...
  Save it to a file (keep it OUT of git — e.g. an underscore-prefixed folder
  that your repos gitignore) and pass --cookie-file, or set JSFIDDLE_COOKIE.
  NOTE: the session cookie is a real credential. Treat it like a password.
 
Usage:
  # update existing fiddle (creates a new version):
  python jsfiddle-push.py update https://jsfiddle.net/Jzapert1/snxczjv5/ \
      --js app.js --css style.css --html index.html --cookie-file _secrets/jsf_cookie.txt
 
  # create a brand-new fiddle:
  python jsfiddle-push.py create --title "My fiddle" --js app.js --cookie-file _secrets/jsf_cookie.txt
 
  # inline code instead of files:
  python jsfiddle-push.py update snxczjv5 --js-code "console.log('hi')" ...
 
Stdlib only (urllib + html.parser). Python 3.9+.
"""
 
import argparse
import html
import json
import os
import re
import sys
import urllib.request
import urllib.parse
from pathlib import Path
 
BASE = "https://jsfiddle.net"
UA = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) fiddle-pipeline/1.0"
 
# Field set observed in the real save/update requests (captured 2026-07-18).
SEND_FIELDS = [
    "username", "authenticity_token", "expiration_days", "description",
    "title", "mistral_api_key", "q", "modalTopMenu", "panel_html", "doctype",
    "body_tag", "panel_js", "js_lib", "js_lib_option", "panel_css",
    "normalize_css", "code_html", "code_css", "code_js",
]
 
 
def http(url, cookie, method="GET", data=None, referer=None):
    headers = {
        "User-Agent": UA,
        "Cookie": cookie,
        "Referer": referer or url,
        "Origin": BASE,
    }
    if data is not None:
        headers["Content-Type"] = "application/x-www-form-urlencoded; charset=UTF-8"
        headers["X-Requested-With"] = "XMLHttpRequest"
        m = re.search(r"csrftoken=([^;]+)", cookie)
        if m:
            headers["X-CSRFToken"] = m.group(1)
        data = urllib.parse.urlencode(data).encode()
    req = urllib.request.Request(url, data=data, headers=headers, method=method)
    with urllib.request.urlopen(req, timeout=30) as resp:
        return resp.status, resp.read().decode("utf-8", errors="replace")
 
 
def parse_form_fields(page: str) -> dict:
    """Extract form state from the server-rendered editor page.
    Inputs (radios/checkboxes only when checked), textareas, selects."""
    fields = {}
    for m in re.finditer(r"<input\b[^>]*>", page):
        tag = m.group(0)
        name = _attr(tag, "name")
        if not name or name in fields:
            continue
        typ = _attr(tag, "type") or "text"
        if typ in ("radio", "checkbox") and not re.search(r"\bchecked\b", tag):
            continue
        fields[name] = html.unescape(_attr(tag, "value") or "")
    for m in re.finditer(r'<textarea\b[^>]*name="([^"]*)"[^>]*>([\s\S]*?)</textarea>', page):
        fields.setdefault(m.group(1), html.unescape(m.group(2)))
    for m in re.finditer(r'<select\b[^>]*name="([^"]*)"[^>]*>([\s\S]*?)</select>', page):
        body = m.group(2)
        options = re.findall(r"<option\b[^>]*>", body)
        chosen = next((o for o in options if re.search(r"\bselected\b", o)),
                      options[0] if options else None)
        val = _attr(chosen, "value") if chosen else None
        fields.setdefault(m.group(1), html.unescape(val) if val else "")
    return fields
 
 
def _attr(tag, name):
    m = re.search(r'%s="([^"]*)"' % name, tag)
    return m.group(1) if m else None
 
 
def parse_slug(target: str):
    m = re.search(r"jsfiddle\.net/(?:[\w.-]+/)?(\w+)(?:/(\d+))?/?", target)
    if m:
        return m.group(1), m.group(2)
    return target.strip("/").split("/")[0], None
 
 
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
    ap.add_argument("--expire", help="expiration_days value (e.g. 1); default: keep forever")
    ap.add_argument("--cookie-file", help="file containing the Cookie header string")
    args = ap.parse_args()
 
    cookie = os.environ.get("JSFIDDLE_COOKIE", "")
    if args.cookie_file:
        cookie = Path(args.cookie_file).read_text(encoding="utf-8").strip()
    if not cookie:
        sys.exit("No cookie: pass --cookie-file or set JSFIDDLE_COOKIE (see header docs).")
 
    if args.action == "update":
        if not args.target:
            sys.exit("update requires a fiddle URL or slug")
        slug, _ver = parse_slug(args.target)
        page_url = f"{BASE}/{args.target}/" if "jsfiddle.net" not in args.target \
            else args.target if args.target.endswith("/") else args.target + "/"
        if "jsfiddle.net" not in page_url:
            page_url = f"{BASE}/{slug}/"
        endpoint, method = f"{BASE}/_update/{slug}/", "PATCH"
    else:
        page_url = BASE + "/"
        endpoint, method = f"{BASE}/_save/", "POST"
 
    # 1-2. GET editor page, parse current form state (incl. authenticity_token)
    status, page = http(page_url, cookie)
    if status != 200:
        sys.exit(f"GET {page_url} -> {status}")
    fields = parse_form_fields(page)
    if not fields.get("authenticity_token"):
        sys.exit("No authenticity_token found — is your cookie valid / are you logged in?")
    if not fields.get("username"):
        print("warning: no username in page — cookie may not be a logged-in session", file=sys.stderr)
 
    # 3. Overrides
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
 
    payload = {k: fields.get(k, "") for k in SEND_FIELDS}
 
    # 4. Send
    status, body = http(endpoint, cookie, method=method, data=payload, referer=page_url)
    print(f"{method} {endpoint} -> {status}")
    try:
        print(json.dumps(json.loads(body), indent=2)[:800])
    except Exception:
        m = re.search(r"/(?:[\w.-]+/)?\w{6,}/(?:\d+/)?", body)
        print(body[:400] + ("..." if len(body) > 400 else ""))
        if m:
            print("new fiddle path?:", m.group(0))
 
 
if __name__ == "__main__":
    main()
 
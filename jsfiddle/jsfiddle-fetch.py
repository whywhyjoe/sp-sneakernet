#!/usr/bin/env python3
"""
jsfiddle-fetch.py — grab the source code of a JSFiddle via plain HTTP (no browser).
 
How it works (re-verified 2026-10-01):
  * A plain GET of the editor page  https://jsfiddle.net/{user}/{slug}/{version}/
    returns HTML with an embedded
        <script type="application/json" id="editor-bootstrap">
    whose config.value = {html, css, js} holds the exact panel sources and
    config.fiddle = {slug, version, ...} the resolved version.
    No authentication is required for public fiddles.
    (Until mid-2026 the panels were in <textarea name="code_html|css|js">
    elements instead; that layout is still accepted as a fallback.)
  * The compiled/rendered single-page result lives at
        https://fiddle.jshell.net/{user}/{slug}/{version}/show/
    That endpoint returns 403 unless you send a Referer header pointing at
    itself (the trick used by the jsfiddle-downloader project).
  * Your whole collection can be enumerated via
        https://jsfiddle.net/api/user/{user}/demo/list.json?sort=date&start=N&limit=100
    (JSON fields: framework, version, description, title, url, author,
     latest_version, created). Paginate with start until fewer than
     `limit` entries come back.
 
Usage:
    python jsfiddle-fetch.py https://jsfiddle.net/Jzapert1/snxczjv5/1/ -o out_dir
    python jsfiddle-fetch.py --list Jzapert1          # list all fiddles for a user
    python jsfiddle-fetch.py URL --show               # also save compiled result page
 
Only stdlib is used (urllib), so it runs anywhere Python 3.8+ exists.
"""
 
import argparse
import html
import json
import re
import sys
import urllib.request
from pathlib import Path
 
UA = "Mozilla/5.0 (compatible; fiddle-pipeline/1.0)"
 
 
def http_get(url: str, referer: str | None = None) -> bytes:
    req = urllib.request.Request(url, headers={"User-Agent": UA})
    if referer:
        req.add_header("Referer", referer)
    with urllib.request.urlopen(req, timeout=30) as resp:
        return resp.read()
 
 
def parse_fiddle_url(url: str):
    """Accepts jsfiddle.net/{user}/{slug}[/{version}] or jsfiddle.net/{slug}."""
    m = re.search(
        r"jsfiddle\.net/(?:(?P<user>[\w.-]+)/)?(?P<slug>[\w]+)(?:/(?P<ver>\d+))?/?",
        url,
    )
    if not m:
        sys.exit(f"Could not parse fiddle URL: {url}")
    return m.group("user"), m.group("slug"), m.group("ver")
 
 
def extract_bootstrap(page_html: str) -> dict | None:
    """The editor's embedded config JSON (current page layout), or None."""
    m = re.search(
        r'<script[^>]*id="editor-bootstrap"[^>]*>(.*?)</script>', page_html, re.DOTALL
    )
    return json.loads(m.group(1)).get("config") if m else None


def extract_panels(page_html: str, bootstrap: dict | None) -> dict:
    """Pull the three code panels out of the editor page.

    Exits non-zero if the page matches neither known layout, so a JSFiddle
    redesign fails loudly instead of "succeeding" with no code.
    """
    if bootstrap and isinstance(bootstrap.get("value"), dict):
        value = bootstrap["value"]
        return {lang: value.get(lang) or "" for lang in ("html", "css", "js")}
    panels, found = {}, False
    for lang in ("html", "css", "js"):
        m = re.search(
            r'<textarea[^>]*name="code_%s"[^>]*>(.*?)</textarea>' % lang,
            page_html,
            re.DOTALL,
        )
        found = found or bool(m)
        panels[lang] = html.unescape(m.group(1)) if m else ""
    if not found:
        sys.exit(
            "error: no panel source found in the editor page (no editor-bootstrap "
            "JSON, no code_* textareas). JSFiddle's page layout has probably "
            "changed; see jsfiddle-backend-http-access.md."
        )
    return panels
 
 
def extract_title(page_html: str) -> str:
    m = re.search(r"<title>(.*?)</title>", page_html, re.DOTALL)
    return html.unescape(m.group(1)).strip() if m else "untitled"
 
 
def fetch_fiddle(url: str, out_dir: Path, want_show: bool = False):
    user, slug, ver = parse_fiddle_url(url)
    path = "/".join(p for p in (user, slug, ver) if p)
    editor_url = f"https://jsfiddle.net/{path}/"
 
    page = http_get(editor_url).decode("utf-8", errors="replace")
    bootstrap = extract_bootstrap(page)
    panels = extract_panels(page, bootstrap)
    title = extract_title(page)
    if not ver and bootstrap and (bootstrap.get("fiddle") or {}).get("version") is not None:
        ver = str(bootstrap["fiddle"]["version"])  # record which version "latest" was
 
    out_dir.mkdir(parents=True, exist_ok=True)
    written = []
    for lang, ext in (("html", "html"), ("css", "css"), ("js", "js")):
        if panels[lang].strip():
            p = out_dir / f"fiddle.{ext}"
            p.write_text(panels[lang], encoding="utf-8")
            written.append(p)
 
    meta = {"title": title, "user": user, "slug": slug, "version": ver, "source": editor_url}
    (out_dir / "fiddle.json").write_text(json.dumps(meta, indent=2), encoding="utf-8")
    written.append(out_dir / "fiddle.json")
 
    if want_show:
        show_url = f"https://fiddle.jshell.net/{path}/show/"
        try:
            compiled = http_get(show_url, referer=show_url)  # Referer trick: 403 without it
            p = out_dir / "compiled.html"
            p.write_bytes(compiled)
            written.append(p)
        except Exception as e:
            print(f"warning: /show/ fetch failed ({e}); panel files were still saved")
 
    print(f"Fetched '{title}' ({path})")
    for p in written:
        print(f"  wrote {p}")
 
 
def list_fiddles(user: str):
    start, out = 0, []
    while True:
        url = f"https://jsfiddle.net/api/user/{user}/demo/list.json?sort=date&start={start}&limit=100"
        chunk = json.loads(http_get(url))
        out.extend(chunk)
        if len(chunk) < 100:
            break
        start += len(chunk)
    for f in out:
        print(f"{f.get('url','')}  v{f.get('version','?')}/latest {f.get('latest_version','?')}  {f.get('title','')}")
    print(f"\n{len(out)} fiddles")
    return out
 
 
if __name__ == "__main__":
    ap = argparse.ArgumentParser(description="Fetch JSFiddle source over plain HTTP")
    ap.add_argument("url", nargs="?", help="fiddle URL, e.g. https://jsfiddle.net/user/slug/1/")
    ap.add_argument("-o", "--out", default="fiddle_out", help="output directory")
    ap.add_argument("--show", action="store_true", help="also fetch compiled /show/ page")
    ap.add_argument("--list", metavar="USER", help="list all public fiddles for USER")
    args = ap.parse_args()
 
    if args.list:
        list_fiddles(args.list)
    elif args.url:
        fetch_fiddle(args.url, Path(args.out), want_show=args.show)
    else:
        ap.print_help()
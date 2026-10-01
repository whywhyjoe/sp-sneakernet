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
  * PRIVATE fiddles answer every anonymous GET with HTTP 500 (editor page,
    any version number, even ones that don't exist), 404 on /show/, and are
    missing from list.json (verified 2026-10-01). On a 500/404 this script
    falls back to `node jsfiddle-session.js read|versions`, which use the
    signed-in Playwright profile and print only code + metadata - never the
    cookie or the CSRF token. --signed-in skips the anonymous attempt;
    --anon-only disables the fallback.
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
    python jsfiddle-fetch.py URL --signed-in          # private fiddle: go straight to the profile

Only stdlib is used (urllib); the private-fiddle fallback also needs Node and
the jsfiddle-session.js login (see README.md).
"""
 
import argparse
import html
import json
import re
import subprocess
import sys
import urllib.error
import urllib.request
from pathlib import Path
 
UA = "Mozilla/5.0 (compatible; fiddle-pipeline/1.0)"
SESSION_JS = Path(__file__).with_name("jsfiddle-session.js")
REDIRECTS = (301, 302, 303, 307, 308)
 
 
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
 
 
class _NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, *args, **kwargs):
        return None  # surface 3xx as HTTPError instead of following it
 
 
def version_status(prefix: str, n: int):
    """GET {prefix}/{n}/ without following redirects -> (status, location).
    200 = version n exists under this exact path (i.e. saved by that user);
    302 = it exists but was saved by someone else (redirects to their path);
    404 = no such version."""
    req = urllib.request.Request(f"{prefix}/{n}/", headers={"User-Agent": UA})
    try:
        with urllib.request.build_opener(_NoRedirect).open(req, timeout=30) as resp:
            return resp.status, None
    except urllib.error.HTTPError as e:
        return e.code, e.headers.get("Location")
 
 
class AnonBlocked(Exception):
    """An anonymous probe got neither 200, a redirect nor 404 - a private
    fiddle answers 500 to every version number, so probing can't work."""


def anon_status(prefix: str, n: int) -> int:
    status, _ = version_status(prefix, n)
    if status != 200 and status != 404 and status not in REDIRECTS:
        raise AnonBlocked(status)
    return status


def session_js(cmd: str, url: str) -> str:
    """Run jsfiddle-session.js read|versions; stdout on success, else exit with
    a clear message. Its stdout never holds the cookie or the CSRF token."""
    try:
        r = subprocess.run(["node", str(SESSION_JS), cmd, url], capture_output=True,
                           text=True, encoding="utf-8")
    except FileNotFoundError:
        sys.exit("error: node not found - it is needed to read a private fiddle "
                 "(jsfiddle-session.js).")
    err = r.stderr.strip()
    if r.returncode == 0:
        return r.stdout
    if r.returncode == 3:
        sys.exit("error: this fiddle needs a signed-in read (private?) and the JSFiddle "
                 f"profile is not signed in. The human runs once: node {SESSION_JS} login")
    if r.returncode == 5:
        sys.exit(f"error: signed-in read of {url} failed ({err}): the fiddle is deleted, "
                 "expired, or private to another account. Ask for a fresh URL.")
    if r.returncode == 6:
        sys.exit(f"error: {url} redirects ({err}): that version was not saved by the URL's "
                 "user. Refusing to read another account's version.")
    if r.returncode == 7:
        sys.exit("error: the JSFiddle browser profile is busy (another login/push/fetch is "
                 "using it); retry when it finishes.")
    sys.exit(f"error: jsfiddle-session.js {cmd} failed (exit {r.returncode}): {err}")


def newest_by(user, slug, top: int, status, max_steps: int) -> str:
    """Step down from `top` to the newest version `status(n)` says is 200."""
    if not user:
        return str(top)  # no owner to check against (caller warns)
    for n in range(top, max(top - max_steps, -1), -1):
        if status(n) == 200:
            return str(n)
    sys.exit(f"error: none of versions {max(top - max_steps + 1, 0)}..{top} of {slug} "
             f"were saved by {user}; pass an explicit version in the URL.")


def newest_version(user, slug, mode: str = "auto", max_steps: int = 50) -> str:
    """An unversioned fiddle URL serves the fiddle's BASE version (usually 0),
    not the latest. Find the highest version number (list API, else probe up
    to the first 404), then step down to the newest one saved by `user` -
    other accounts can save versions under the same slug. A private fiddle
    answers 500 to every anonymous probe, so its versions are probed signed in."""
    prefix = f"https://jsfiddle.net/{user + '/' if user else ''}{slug}"
    if mode != "signed-in":
        try:
            top = None
            if user:
                try:
                    for f in list_fiddles(user, quiet=True):
                        if f.get("url", "").rstrip("/").endswith("/" + slug):
                            top = int(f.get("latest_version", 0))
                except Exception:
                    pass  # API change -> probe (private fiddles are just absent)
            if top is None:
                top = 0
                while anon_status(prefix, top + 1) != 404:
                    top += 1
            return newest_by(user, slug, top, lambda n: anon_status(prefix, n), max_steps)
        except AnonBlocked as e:
            if mode == "anon-only":
                sys.exit(f"error: anonymous version probe of {slug} got HTTP {e} (private "
                         "fiddle?); drop --anon-only or pass a versioned URL.")
            print(f"anonymous version probe got HTTP {e} (private fiddle?) - "
                  "probing versions signed in", file=sys.stderr)
    found = {int(k): v for k, v in json.loads(session_js("versions", prefix)).items()}
    existing = [n for n, st in found.items() if st != 404]
    if not existing:
        sys.exit(f"error: no versions of {slug} found, even signed in.")
    return newest_by(user, slug, max(existing), found.get, max_steps)


def fetch_fiddle(url: str, out_dir: Path, want_show: bool = False, mode: str = "auto"):
    """mode: "auto" (anonymous, signed-in fallback on 500/404), "anon-only",
    or "signed-in" (skip the anonymous attempt)."""
    user, slug, ver = parse_fiddle_url(url)
    if not user:
        print("warning: no user in URL - cannot check who saved this version", file=sys.stderr)
    if ver is None:
        ver = newest_version(user, slug, mode)
        print(f"no version in URL -> newest version{' by ' + user if user else ''} is v{ver}")
    path = "/".join(p for p in (user, slug, ver) if p)
    editor_url = f"https://jsfiddle.net/{path}/"

    page = None  # anonymous editor HTML; stays None on the signed-in path
    if mode != "signed-in":
        status = None
        if user:
            status, location = version_status(f"https://jsfiddle.net/{user}/{slug}", int(ver))
            if status in REDIRECTS:
                sys.exit(f"error: v{ver} of {slug} was not saved by {user} (redirects to "
                         f"{location}). Refusing to read another account's version.")
        if status in (None, 200):
            try:
                page = http_get(editor_url).decode("utf-8", errors="replace")
            except urllib.error.HTTPError as e:
                status = e.code
        if page is None and (mode == "anon-only" or status not in (404, 500)):
            sys.exit(f"error: anonymous GET of {editor_url} returned HTTP {status}"
                     + (" (private fiddle? drop --anon-only)" if mode == "anon-only" else ""))
        if page is None:
            print(f"anonymous GET returned HTTP {status} (private fiddle?) - "
                  "reading signed in", file=sys.stderr)

    if page is not None:
        bootstrap = extract_bootstrap(page)
        panels = extract_panels(page, bootstrap)
        title = extract_title(page)
        read_as = "anonymous"
    else:
        # Redirects (another account's version) are refused inside `read`.
        bootstrap = json.loads(session_js("read", editor_url))["config"]
        panels = extract_panels("", bootstrap)
        title = (bootstrap.get("header") or {}).get("title") or "untitled"
        read_as = "signed-in"
    fiddle = (bootstrap or {}).get("fiddle") or {}
    if "version" in fiddle and str(fiddle["version"]) != str(ver):
        sys.exit(f"error: asked for v{ver} but the page served v{fiddle['version']}.")
    private = bool(fiddle.get("private"))

    out_dir.mkdir(parents=True, exist_ok=True)
    written = []
    for lang, ext in (("html", "html"), ("css", "css"), ("js", "js")):
        if panels[lang].strip():
            p = out_dir / f"fiddle.{ext}"
            # newline="": write the panel exactly - no LF -> CRLF translation on Windows
            p.write_text(panels[lang], encoding="utf-8", newline="")
            written.append(p)
 
    meta = {"title": title, "user": user, "slug": slug, "version": ver, "source": editor_url,
            "private": private, "read": read_as}
    (out_dir / "fiddle.json").write_text(json.dumps(meta, indent=2), encoding="utf-8")
    written.append(out_dir / "fiddle.json")
 
    if want_show and private:
        print("warning: --show skipped - a private fiddle's /show/ is 404 without a "
              "short-lived signed token; panel files were still saved")
    elif want_show:
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
 
 
def list_fiddles(user: str, quiet: bool = False):
    start, out = 0, []
    while True:
        url = f"https://jsfiddle.net/api/user/{user}/demo/list.json?sort=date&start={start}&limit=100"
        chunk = json.loads(http_get(url))
        out.extend(chunk)
        if len(chunk) < 100:
            break
        start += len(chunk)
    if not quiet:
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
    g = ap.add_mutually_exclusive_group()
    g.add_argument("--signed-in", action="store_true",
                   help="read via the jsfiddle-session.js profile only (private fiddles)")
    g.add_argument("--anon-only", action="store_true",
                   help="never fall back to the signed-in profile")
    args = ap.parse_args()
    mode = "signed-in" if args.signed_in else "anon-only" if args.anon_only else "auto"
 
    if args.list:
        list_fiddles(args.list)
    elif args.url:
        fetch_fiddle(args.url, Path(args.out), want_show=args.show, mode=mode)
    else:
        ap.print_help()
#!/usr/bin/env python3
"""
jsfiddle-unpack.py — turn a fetched sneakernet fiddle back into files, a patch,
or results. Pairs with the prod-side tools/sp/send-to-dev.js.

    python jsfiddle-unpack.py <fetch-dir | fiddle.js> --into <repo-dir> [--dry-run] [--force]

The fiddle's JS panel starts with `// SNEAKERNET {header}` (kind, project, base
sha, count), then a `throw` guard line (dropped here). By kind:
  files    each `// FILE: {path, sha256, eol, finalNewline}` block is rebuilt
           byte-exact under --into, sha256-verified (on LF-normalized text, so
           the browser's CRLF form encoding doesn't matter). Paths must be
           plain relative paths. A file the target repo has UNCOMMITTED changes
           to is refused unless --force. New dirs are created.
  diff     the patch is LF-normalized, saved as sneakernet.patch next to the
           fiddle, `git apply --check`ed in --into, then applied (falls back to
           --ignore-whitespace). Mismatched base sha is reported, not fatal.
  results  the JSON is saved as results.json next to the fiddle and summarized;
           --into is not needed.
No header (hand-pasted): JSON -> results; starts with `diff --git` -> diff;
`// FILE: <path>` markers (plain paths, no hashes) -> files.

--dry-run prints what would happen and changes nothing. Exit non-zero on any
hash mismatch, unsafe path, refused overwrite, or failed patch check.
Stdlib only. Python 3.10+.
"""

import argparse
import hashlib
import json
import re
import subprocess
import sys
from pathlib import Path, PurePosixPath

HEADER = "// SNEAKERNET "
MARK = "// FILE: "
GUARD_PREFIX = 'throw new Error("sneakernet payload'


def die(msg):
    sys.exit(f"jsfiddle-unpack: {msg}")


def safe_rel(p: str) -> PurePosixPath:
    q = PurePosixPath(p)
    if (not p or "\\" in p or ":" in p or q.is_absolute()
            or any(part in ("", ".", "..") for part in q.parts)
            or re.search(r"[\x00-\x1f]", p)):
        die(f"unsafe path in payload: {p!r}")
    return q


def git(repo, *args):
    return subprocess.run(["git", "-C", str(repo), *args], capture_output=True, text=True)


def split_files(body: str):
    """Yield (meta, text) per FILE block, text LF-normalized. In the payload
    every block's content is followed by exactly one terminator newline (the
    file's own final newline, or a synthetic one when finalNewline is false)."""
    starts = [m.start() for m in re.finditer(r"(?m)^" + re.escape(MARK), body)]
    if not starts:
        die("no `// FILE:` markers")
    if body[:starts[0]].strip():
        die("content before the first `// FILE:` marker")
    for i, st in enumerate(starts):
        nl = body.find("\n", st)
        spec = body[st + len(MARK):nl if nl != -1 else len(body)].strip()
        raw = "" if nl == -1 else body[nl + 1:starts[i + 1] if i + 1 < len(starts) else len(body)]
        meta = json.loads(spec) if spec.startswith("{") else {"path": spec}
        text = raw[:-1] if raw.endswith("\n") else raw
        # Undo the packer's escaping of marker-looking content lines.
        text = re.sub(r"(?m)^\\(\\*// (?:FILE:|SNEAKERNET) )", r"\1", text)
        if meta.get("finalNewline", True):
            text += "\n"
        yield meta, text
 
 
def unpack_files(body, into: Path, dry, force):
    into = into.resolve()
    is_repo = git(into, "rev-parse", "--show-toplevel").returncode == 0 if into.exists() else False
    plan, bad = [], []
    for meta, text in split_files(body):
        rel = safe_rel(meta["path"])
        if "sha256" in meta:
            got = hashlib.sha256(text.encode("utf-8")).hexdigest()
            if got != meta["sha256"]:
                bad.append(f"hash mismatch: {rel} (payload damaged or edited in the browser)")
                continue
        data = text.replace("\n", "\r\n") if meta.get("eol") == "crlf" else text
        dest = into / Path(*rel.parts)
        if dest.exists():
            cur = dest.read_bytes()
            if cur == data.encode("utf-8"):
                plan.append(("same", rel, dest, data))
                continue
            if is_repo and not force and git(into, "status", "--porcelain", "--", str(dest)).stdout.strip():
                bad.append(f"refused: {rel} has uncommitted changes in {into} (commit/stash, or --force)")
                continue
            plan.append(("modify", rel, dest, data))
        else:
            plan.append(("create", rel, dest, data))
    for action, rel, _, _ in plan:
        print(f"  {action:6} {rel}")
    if bad:
        print("\n".join("  " + b for b in bad), file=sys.stderr)
        die(f"{len(bad)} problem(s); nothing written")
    if dry:
        print("dry run - nothing written")
        return
    for action, _, dest, data in plan:
        if action == "same":
            continue
        dest.parent.mkdir(parents=True, exist_ok=True)
        dest.write_bytes(data.encode("utf-8"))
    n = sum(a != "same" for a, *_ in plan)
    print(f"wrote {n} file(s) under {into}" + (" - review with `git status` / `git diff`" if is_repo else ""))


def unpack_diff(body, header, into: Path, out_dir: Path, dry):
    patch = body.replace("\r\n", "\n")
    if not patch.endswith("\n"):
        patch += "\n"
    pfile = (out_dir / "sneakernet.patch").resolve()
    pfile.write_text(patch, encoding="utf-8", newline="\n")
    print(f"patch: {pfile}")
    if not into or not (into / ".git").exists() and git(into, "rev-parse").returncode != 0:
        die("--into must be the target git repo for a diff")
    base = (header or {}).get("sha")
    if base:
        here = git(into, "rev-parse", "--short", "HEAD").stdout.strip()
        if not here.startswith(base[:7]) and not base.startswith(here[:7]):
            print(f"note: prod's base was {base}, this repo is at {here} - the patch may not apply cleanly")
    for extra in ([], ["--ignore-whitespace"]):
        chk = git(into, "apply", "--check", *extra, str(pfile))
        if chk.returncode == 0:
            print("git apply --check: OK" + (" (with --ignore-whitespace)" if extra else ""))
            if dry:
                print("dry run - not applied")
                return
            res = git(into, "apply", *extra, str(pfile))
            if res.returncode != 0:
                die("git apply failed: " + res.stderr.strip())
            print("applied - review with `git status` / `git diff`")
            return
    die("patch does not apply:\n" + chk.stderr.strip())


def unpack_results(body, out_dir: Path):
    try:
        data = json.loads(body)
    except ValueError as e:
        die(f"results payload is not valid JSON: {e}")
    rfile = out_dir / "results.json"
    rfile.write_text(json.dumps(data, indent=2), encoding="utf-8")
    rows = data if isinstance(data, list) else [data]
    for r in rows:
        if isinstance(r, dict):
            print(f"  suite={r.get('suite', '?')} passed={r.get('passed', '?')}")
    print(f"results: {rfile}")


def main():
    ap = argparse.ArgumentParser(description="Unpack a sneakernet fiddle (files / diff / results)")
    ap.add_argument("source", help="jsfiddle-fetch.py output dir, or its fiddle.js")
    ap.add_argument("--into", help="target directory / git repo (files, diff)")
    ap.add_argument("--dry-run", action="store_true")
    ap.add_argument("--force", action="store_true", help="overwrite files with uncommitted changes")
    args = ap.parse_args()

    src = Path(args.source)
    js = src / "fiddle.js" if src.is_dir() else src
    if not js.exists():
        die(f"{js} not found - fetch the fiddle first (jsfiddle-fetch.py URL -o DIR)")
    text = js.read_text(encoding="utf-8").replace("\r\n", "\n")

    header, body = None, text
    if text.startswith(HEADER):
        first, _, body = text.partition("\n")
        header = json.loads(first[len(HEADER):])
        if body.startswith(GUARD_PREFIX):  # send-to-dev's anti-autorun line
            body = body.partition("\n")[2]
        kind = header.get("kind")
        print(f"sneakernet {kind} from {header.get('project')} @ {header.get('sha')} "
              f"({header.get('branch')}), {header.get('count')} item(s), sent {header.get('created')}")
    elif body.lstrip().startswith("diff --git"):
        kind = "diff"
    elif any(l.startswith(MARK) for l in body.split("\n")):
        kind = "files"
    else:
        try:
            json.loads(body)
            kind = "results"
        except ValueError:
            die("can't tell what this is (no SNEAKERNET header, not a diff, no FILE markers, not JSON)")

    if kind == "results":
        unpack_results(body, js.parent)
    elif kind in ("files", "diff"):
        if not args.into:
            die(f"--into is required for {kind}")
        into = Path(args.into)
        if kind == "files":
            unpack_files(body, into, args.dry_run, args.force)
        else:
            unpack_diff(body, header, into, js.parent, args.dry_run)
    else:
        die(f"unknown kind {kind!r}")


if __name__ == "__main__":
    main()

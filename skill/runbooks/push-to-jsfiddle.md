# push-to-jsfiddle (dev, agent) — write a fiddle from dev

The write half of the JSFiddle bridge, run by the dev agent. Typical uses:

- **Set up the drop box** — create the fiddle the prod human will paste
  results or a `git diff` into, and hand them its URL.
- **Hand prod a snippet** — a one-off console script or harness tweak the
  human can copy from the fiddle when a `git pull` round trip is overkill.
  Code that ships still goes through git; a fiddle is a scratchpad, not a
  deploy channel.

**You need:** the sneakernet repo at `localRepos.sneakernet` in
`tenants.local.json` (scripts in its `jsfiddle/`), Python 3.10+, Node, and
the Playwright copy installed with this skill. The JSFiddle login lives in a
dedicated Edge profile (`<sneakernet>/_secrets/jsfiddle-profile`,
gitignored).

## Steps

1. Check the login (headless, prints no credential):

   ```
   node <sneakernet>/jsfiddle/jsfiddle-session.js status
   ```

   `{"signedIn":true,...}` / exit 0 → go on. Exit 3 → the push in step 2
   opens Edge on the JSFiddle login page and waits up to 15 minutes. Tell the
   user to log in there — signing in is the one sanctioned human step (§0);
   everything after it is yours.
2. Push:

   ```
   python <sneakernet>/jsfiddle/jsfiddle-push.py create --title "<project>: <purpose>" --js <file> [--expire 30]
   python <sneakernet>/jsfiddle/jsfiddle-push.py update https://jsfiddle.net/<user>/<slug>/ --js <file>
   ```

   Panels: `--html/--css/--js <file>` or `--html-code/--css-code/--js-code
   "<text>"`; omitted panels keep their current content. `update` makes a new
   version and keeps title, expiry and settings unless overridden. Success =
   `-> 200` and a `fiddle: https://jsfiddle.net/<user>/<slug>/<n>/` line.
3. Verify it yourself: `jsfiddle-fetch.py <that URL> -o <scratch>/check` and
   diff against what you pushed. Then give the user the versioned URL.

## Rules

- **Fiddles are public.** Never push tenant URLs, site paths, list data,
  credentials, or anything from `tenants.local.json` / `env.local.json`. Push
  logical names and generic code only. Use `--expire` for anything temporary.
- **Never run `jsfiddle-session.js cookie` yourself** and never pass
  `--cookie-file` / `JSFIDDLE_COOKIE` — the push script fetches the session
  in memory; the cookie must not land in output, logs or files.
- Run pushes one at a time — the Edge profile can't be opened twice
  (`profile_locked`-style launch error → wait for the other run, retry).
- `"Not signed in"` / `"no update path for '<slug>'"` → stale login (rerun,
  it reopens Edge) or a slug that isn't the logged-in user's.
- Request format and endpoints: `jsfiddle/jsfiddle-backend-http-access.md`.
  If pushes start failing after a JSFiddle change, re-capture there first.

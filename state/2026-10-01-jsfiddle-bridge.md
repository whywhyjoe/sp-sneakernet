# State — JSFiddle bridge (prod ↔ dev)

Last touched: 2026-10-01
Mode: Joe
Branch: master, pushed (c341b47)
State: built and verified on the dev machine; never yet run on a real work (prod) machine.

## What this is

JSFiddle is the only way data leaves the locked-down work tenant. The bridge has three parts:

- **Prod side, per project:** `tools/sp/send-to-dev.js`, stamped from
  `skill/templates/project/tools/sp/`. It packs results JSON, an uncommitted diff, or whole
  files, checks them for secrets and tenant facts, and opens a *prefilled* JSFiddle. The
  human reviews and saves.
- **Dev side, this repo:** in `jsfiddle/`, `jsfiddle-fetch.py` and `jsfiddle-unpack.py` read
  the fiddle back. `jsfiddle-push.py` and `jsfiddle-session.js` write fiddles from dev using a
  Playwright Edge login.
- **The sp-env skill:** procedures in the runbooks `export-results`, `import-from-jsfiddle`
  and `push-to-jsfiddle`.

## Done

- Everything above is committed and pushed, and installed via `install.ps1`.
- Verified on dev:
  - 14-case round-trip suite, with browser CRLF line endings simulated.
  - A live prefill, saved as `Jzapert1/9o5231pd` (1-day expiry), fetched and unpacked
    byte-exact.
  - A live push, `Jzapert1/zrsbv5nf` v3 (1-day expiry), through the Edge-profile login.
- Decision (user): existing projects get `send-to-dev.js` when they are next worked on at dev
  time, not by a sweep. Encoded in `skill/SKILL.md` §4 "Existing project, older scaffold".

## Next

- [ ] First real prod run, on the work machine, in a project that has `send-to-dev.js` (none
      in bsp-sp-parts do yet; see Landmines). Confirm each of these:
      - Node is present.
      - `powershell Get-Clipboard` works (`results` mode).
      - `cmd /c start` opens the default browser on the prefilled editor.
      - The corporate proxy lets the form POST through to `jsfiddle.net/api/post/library/pure/`.
      - The saved URL includes `<user>/<slug>/<n>`.

      Record what failed in `jsfiddle/jsfiddle-backend-http-access.md`.
- [ ] On that same run, check whether Copilot on the work machine reads `.claude/skills`
      (see `skill/runbooks/copilot-agent-skills-findings.md`, still unproven).
      `.github/copilot-instructions.md` is the guaranteed channel either way.

## Companion documents

- `jsfiddle/jsfiddle-backend-http-access.md` — **live** reference: endpoints, bootstrap-JSON
  mapping, prefill behaviour, version/author traps. Update it whenever JSFiddle changes.

## Landmines

- The prefilled editor **autoruns** the JS panel. Line 2 of every `send-to-dev.js` payload is
  a `throw` guard. Never remove it.
- An unversioned fiddle URL serves the base version (often v0), not the latest, and other
  accounts can save versions under any slug. `jsfiddle-fetch.py` handles both; don't
  "simplify" that logic away.
- Never run `jsfiddle-session.js cookie` from an agent; it prints the session cookie. The
  push script calls it and keeps the cookie in memory.
- Fiddles are public. `send-to-dev.js` blocks `env.local.json` values and secrets; don't
  weaken those checks.
- **bsp-sp-parts:**
  - `admin-script-runner` exists only on the unpushed local branch `admin-script-runner`.
    Its copilot-instructions update is local commit `71962af`.
  - `bsp-notify` on `main` has the older manual-paste instructions, not `send-to-dev.js`.
    That's intended until it is next worked on.
- The `.gitignore`d `_secrets/` holds the JSFiddle Edge login profile. Don't delete it unless
  you want to log in again.

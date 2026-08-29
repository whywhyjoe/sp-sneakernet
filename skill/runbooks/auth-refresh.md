# auth-refresh (dev, run whenever auth looks stale — then retry the failed step)

**What it does:** checks both auth paths with structured failure classification.
(a) PnP app-only cert connect + `Get-PnPWeb`; (b) headless Playwright open of the
dev site using the persistent profile, probing auth via an in-page REST call.

`auth-check.js` classifies failures: `ok` (exit 0), `auth_stale` (exit 3 — login
redirect or REST 401/403), or a tooling kind (exit 4): `browser_missing`,
`profile_locked`, `network`, `timeout`, `tooling`. **Only `auth_stale` triggers
the headed re-login** (the one case needing a human, for credential entry).
Tooling failures are reported as tooling failures — an interactive login is never
offered as a fix for them.

**How to call:**
```powershell
pwsh -File ~/.claude/skills/sp-env/scripts/auth-refresh.ps1              # auto re-login only if auth_stale
pwsh -File ~/.claude/skills/sp-env/scripts/auth-refresh.ps1 -NoRelogin   # report only, never open a window
```

**How it verifies:** prints `AUTH-REFRESH-RESULT {pnp:{ok,…}, playwright:{ok,…}}`
and exits 0 only when both are healthy. A PnP failure is NOT auto-repaired —
run `setup-dev-auth.ps1` (with `-Rotate` for cert/app problems) and report the
exact error.

**Agent rule:** on any SharePoint 401/login-redirect during dev work, run this,
then retry the original step. Never end the task by asking the human to check
their session.

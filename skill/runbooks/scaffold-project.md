# scaffold-project (start every new SharePoint project this way)

**What it does:** stamps a complete sp-env project repo from
`templates/project/`: `env.json` (with the project name), `.gitignore`,
dev `env.local.json`, `tools/sp/` (deploy.ps1 copy-mode, bootstrap-dev.ps1,
reset-dev.ps1, run-harness.js, a fresh resolver copy), `app/` (harness.js,
provision.js, verify.js, test-smoke.js, loader.js, app.js, sewp-snippet.html),
and the thin `.claude/skills/sp-project` pointer. Refuses to overwrite an
existing `env.json`, and proves the stamped repo resolves before reporting OK.

**How to call:**
```powershell
pwsh -File ~/.claude/skills/sp-env/scripts/scaffold-project.ps1 -Path C:\dev\repos\my-app -Project my-app
```

**Then:** edit `env.json` (real lists/columns/seed/pages; verify
`libraries.pnp2.path` matches the actual bundle filename in the shared lib
root) → `deploy.ps1` → first time `bootstrap-dev.ps1` → run each op as its own
command (these are separate invocations, not a pipeline):
`node tools/sp/run-harness.js provision`, then `… verify`, then
`… test-smoke` — each prints its correlated TestRuns row. Full workflow:
SKILL.md §4.

**One-time site prep (per site, not per project):** a modern page
`SitePages/_app-template.aspx` whose Script Editor Web Part contains the
content of `app/sewp-snippet.html` (the literal `__SP_ENV_SCRIPT__` token).
bootstrap-dev and provision copy it to create harness/app pages.

**How it verifies:** prints `SCAFFOLD-OK` only after a live resolver run
against the stamped repo succeeds.

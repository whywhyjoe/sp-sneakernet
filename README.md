# sp-env — SharePoint Two-Tenant Dev/Prod Tooling

Tooling and agent instructions for building SharePoint-hosted apps on a personal dev tenant and shipping them to a locked-down corporate tenant, where the AI agent can only clone, not push, and the only way data leaves is a human pasting into JSFiddle.

This README is the "why." `sp-two-tenant-handoff.md` is the "how."

---

## The problem

Every SharePoint project I build goes through the same loop:

1. Build and test on my own M365 tenant, where I'm global admin and have every tool.
2. Clone the repo onto a corporate machine that can reach GitHub read-only.
3. Re-create the lists, pages, and libraries by hand, deploy files through a OneDrive sync folder, and test by clicking around.
4. Discover something's different, fix it on dev, repeat.

Two things make this expensive:

- **The AI agent doesn't know the terrain.** Every session I re-explain which tenant is which, where scripts live, that prod has no PnP PowerShell, that Copilot on prod has a tiny token budget, that results come back through JSFiddle. That context should be read from a file, not typed.
- **On dev, the agent stops short of the finish line.** It changes a list, then says "next, open the page and confirm it works." It has a browser. It has credentials. It should confirm it itself.

## Goals

1. **The agent knows both environments cold.** Tenants, sites, library conventions, what tooling exists where, what's forbidden where. Encoded once, read every session.
2. **Dev is fully closed-loop.** Claude Code provisions, deploys, opens the page in a real browser, runs the tests, reads the results back, and reports. No human verification step on dev. If a step can't be automated, that's a tooling bug to fix, not a task to hand back.
3. **Prod is script-driven and cheap.** Copilot on prod runs deterministic scripts and reads pasted results. It doesn't reason about SharePoint; it doesn't need a frontier model.
4. **One provisioner, one verifier.** Lists, columns, libraries, and pages are declared in a manifest and applied by the same PnPjs code on both tenants. Drift between dev and prod is detected, not discovered.
5. **Deploy scales down.** Small projects copy files into a synced folder. Bigger ones get metadata-stamped browser pushes or the full sync pipeline. Same manifest, different `deploy.mode`.
6. **Reusable across projects.** Tenant knowledge lives in one global skill; each repo carries only its own manifest and a thin pointer.

## Non-goals

- Replacing GitHub as the transport into prod. Public clone is the constraint; we work inside it.
- Pushing anything out of prod automatically. JSFiddle paste stays manual by design.
- SPFx. Apps are plain scripts loaded by a Script Editor Web Part on a modern page.
- Multi-agent orchestration. One Claude Code on dev, one Copilot on prod.
- Premium Power Platform features. Connection references get re-bound by hand on import; naming discipline makes that mechanical.

## The two environments

| | dev | prod |
|---|---|---|
| Who owns it | Me (global admin) | Corporate IT |
| Agent | Claude Code | GitHub Copilot (VS Code / CLI), minimal tokens |
| Server-side tooling | PnP PowerShell (app-only cert auth), `pac` CLI | None |
| Browser tooling | Playwright with a persistent logged-in profile | A human with a browser |
| Script execution on SP | Harness page (PnPjs) | Harness page (PnPjs), browser console |
| Git | Full | `clone` / `pull` from public HTTPS only |
| Data out | Anything | JSFiddle paste only |

Dev mirrors prod structurally — same logical list names, page names, library names, and flow names. The tenant root **and the library root paths** differ per tenant (they are not the same site-relative paths), and both are resolved through machine-local config (`tenants.local.json` / `env.local.json`) — never from a repo.

## Principles

- **Facts in files, procedure in scripts, judgment in the agent.** The skill holds environment facts and rules. Runbooks are scripts with a one-page doc each. The agent decides what to run and interprets results.
- **Logical names everywhere.** Code and manifests refer to `libraries.scripts` or `pages.app`, never to a URL. Resolution happens through a gitignored local file on each machine.
- **Idempotent by default.** `provision` and `deploy` can run twice safely. `reset-dev` exists so a clean run is one command.
- **Same code path both sides.** Anything that must work on prod is written in PnPjs and run from the harness page. PnP PowerShell is a dev convenience for the things browsers can't do (site reset, solution export).
- **Results are data, not screenshots.** Tests post to a `TestRuns` list. Dev reads it via REST; prod serializes it to JSON for the JSFiddle bridge.
- **Verified means the agent saw it.** On dev, "done" includes a Playwright-driven check with results read back. The phrases "please confirm in the browser" and "next step: check your session" are defects.

## How the pieces fit

```
global skill (~/.claude/skills/sp-env)
   facts: tenants, constraints, conventions, runbook index
   secrets-adjacent: tenant URLs, cert pointer (never in a repo)
         │
         ▼
repo
   env.json              what this project needs (lists, pages, libraries, flows, deploy mode)
   env.local.json        where that lives on this machine (gitignored)
   tools/sp/             provision · verify · deploy · reset-dev · run-harness · pp-export
   harness.html          SEWP-hosted runner: loads a script, runs it, writes TestRuns
   .claude/skills/       thin pointer → global skill
   .github/copilot-instructions.md   generated, prod-only, short
```

Dev flow: `reset-dev` → `provision` → `verify` → `deploy` → `test` → agent reads `TestRuns` → done.
Prod flow: `git pull` → `deploy -mode copy` → human opens harness → runs `verify` + `test` → copies JSON → pastes to JSFiddle → Copilot summarizes.

## Standing conventions

- PnPjs custom bundle exposed as `window.pnp2`; call `sp.setup({ sp: { baseUrl: _spPageContextInfo.webAbsoluteUrl } })` first.
- No ES module imports in code that ships to SharePoint.
- Deploys overwrite in place. Low traffic; "try again" is an acceptable failure mode.
- Git bundle transport for offline contributors: `main.bundle` in the synced folder, `inbox\` for incoming bundles.
- `push` deploys stamp `BuildId`, `GitSha`, `DeployedBy`, `Note` on each file.
- Flow names and list names are identical across tenants so connection rebinding on prod import is a lookup, not a puzzle.

## Glossary

- **Harness page** — a modern page with a Script Editor Web Part that loads a named script from the scripts library, runs it, and records the outcome. The universal execution surface on both tenants.
- **Manifest** — `env.json`. The declarative description of what a project needs on SharePoint.
- **Runbook** — a script plus a one-page doc. The unit of work an agent invokes.
- **JSFiddle bridge** — the only egress from prod: a human pastes a JSON blob or script into a fiddle; dev reads it from there. Tooling for the fiddle side lives in [`jsfiddle/`](jsfiddle/): stdlib-only Python CLI scripts to fetch/push fiddles on jsfiddle.net, plus reverse-engineering notes on the backend HTTP access.
- **Deploy mode** — `copy` (Copy-Item into the OneDrive mirror), `push` (browser uploader with metadata), `sync-live` (full pipeline with manifest and mirror rules).

## Status

**Built.** All five phases of `sp-two-tenant-handoff.md` are implemented and live-verified: the versioned skill source lives in `skill/`, and `install.ps1` deploys it to `~/.claude/skills/sp-env` while preserving machine-local state (tenant config, auth pointers, browser profile). The pilot project proved the loop end-to-end in a fresh session.

**→ [USING.md](USING.md) is the user guide** — what the system does, when things happen, and where the technical details live. This README stays as the problem statement; the handoff doc stays as the build spec.

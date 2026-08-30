# Using sp-env — the user guide

This repo used to be a plan. It is now a **built, working system**: a global
Claude Code skill that lets you start any SharePoint project with one sentence
and get a provisioned, deployed, self-verified app on the dev tenant — plus a
documented, human-driven path for shipping it to the locked-down work tenant.

This page is the overview: what it does, when things happen, and where the
technical detail lives. It deliberately skips the internals.

---

## What it does

- **You say:** *"New SharePoint project on dev: a list of X and a page that
  shows Y."* — in a fresh Claude Code session, in any new empty repo. No
  skill names, no URLs, no setup preamble.
- **The agent does:** reads the global `sp-env` skill automatically, scaffolds
  the repo (manifest, tooling, app skeleton), provisions the lists/pages on
  the dev site, deploys through the OneDrive mirror, runs the test harness in
  a real logged-in browser, and reads the results back from the TestRuns list
  itself. You never get asked to "open the page and check."
- **Every run is evidence-backed:** each harness run writes a row to the
  TestRuns list with a unique run id, and the tooling only reports success
  after reading its own row back.

The same skill also covers **one-off divergent work** ("make a page that does
X" — no repo needed), and carries opt-in knowledge tiers that activate only
when you name them:

| You say… | The agent uses… |
|---|---|
| nothing special | the simple project scaffold (the default) |
| "BSP part / BSP project" | the `bsp-sp-parts` repo's four-artifact pattern |
| canvas app work | the IanI-derived operating rules (sync ritual, Studio traps) |
| flow / solution work | `pp-export` — solutions are for **flows only**, for versioning |

## When things happen

**Automatically, every session:** the skill loads (it's global), URLs resolve
from machine-local config (never from a repo), and existing auth is reused —
a certificate for PowerShell and a persistent browser profile for Playwright.

**When auth goes stale:** the agent runs `auth-refresh` and retries on its
own. You're only pulled in for an actual Microsoft sign-in — that's the one
category of step that is always yours.

**When sync stalls:** deploys go through OneDrive-synced mirror folders
(intentional junctions, same path on every machine). If files don't land, the
agent checks whether OneDrive is running and reports — it is forbidden from
"fixing" sync configuration.

**When you ship to work (all human-driven, by design):** clone the repo on
the work machine, deploy by copy, open the harness page in your browser, run
verify/test, and paste the results JSON back (the JSFiddle bridge). Flow
solutions import manually in the maker portal from the committed
`packages/*.zip`. The generated `.github/copilot-instructions.md` in each
project tells the work-side Copilot its (deliberately narrow) job.

## Your moments (the complete list)

1. Microsoft sign-ins and admin consent (auth setup, rotation, pac).
2. Starting OneDrive if it isn't running.
3. Everything on the prod tenant: running the harness, pasting results,
   importing solutions, rebinding connections.
4. Saving in Power Apps Studio during canvas work (a push isn't durable until
   you Ctrl+S).

Everything else — provisioning, deploying, testing, verifying — is the
agent's job, and it's a defect (not a favor to you) if it hands one back.

## Where the technical details live

| Topic | Where |
|---|---|
| The rules, environment facts, workflows, gotchas | [skill/SKILL.md](skill/SKILL.md) — the master document; §0 is the verification hard rule, §4 the project workflow |
| Every runbook (auth, scaffold, deploy, prod import, results export…) | [skill/runbooks/INDEX.md](skill/runbooks/INDEX.md) |
| What a scaffolded project contains | [skill/templates/project/](skill/templates/project/) — each script's header comment documents its contract |
| Machine-local facts (tenant URLs, mirrors, env ids, related-repo paths) | `~/.claude/skills/sp-env/tenants.local.json` — **never in this repo** |
| Original problem statement and design | [README.md](README.md) and [sp-two-tenant-handoff.md](sp-two-tenant-handoff.md) |
| BSP part pattern | the `bsp-sp-parts` repo (path in tenants.local.json) |
| Canvas app deep reference | the IanI app repo's `BUILD-AND-SHIP.md` (path in tenants.local.json) |
| Example flow-solution export artifact | [examples/pp-export-throwaway/](examples/pp-export-throwaway/) |

## Maintaining it

The `skill/` directory **in this repo** is the source of truth; the installed
copy under `~/.claude/skills/sp-env` is a build artifact. To change the skill:
edit here, run `./install.ps1` (it validates everything before touching the
live install), commit. When a project session hits something the skill didn't
know — a tenant quirk, a broken assumption — the fix belongs *here*, so every
future session inherits it. That loop is the whole point of the system.

```bash
pwsh -File ./install.ps1
```

## Current status / open items

Built and verified through all five planned phases, plus three external
review rounds (findings fixed or explicitly deferred — see git log). Open:
this repo has no remote yet (prod ingestion needs a public GitHub clone), and
the prod-side path is documented but not yet exercised on a real work-machine
ship — do a rehearsal on a throwaway before the first real one.

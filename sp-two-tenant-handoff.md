# SharePoint Two-Tenant Dev/Prod Tooling — Plan & Claude Code Handoff

## 0. The one rule (dev side)

**On dev, Claude Code verifies outcomes itself in a live browser. It never hands verification to the human.**

"Done" for any dev task that touches SharePoint means all of the following happened in the same session:

1. The change was applied (PnP PS or PnPjs via harness page).
2. `verify` was run and reported no drift.
3. The relevant page was opened in Playwright (persistent auth profile), the harness/test ran, and the results were read back from the `TestRuns` list or REST — by Claude Code, not by the user.
4. If the browser session is stale, Claude Code runs `auth-refresh` and retries; if that fails, it reports the failure with the exact error, not "next step: check your auth."

Forbidden output patterns on dev: "next, you should open…", "please confirm in the browser that…", "check whether the session is authenticated…". If the tooling can't do it, the tooling is the bug — fix or report the tooling.

Prod is the opposite: the human runs the harness page; the agent only prepares scripts and reads back what the human pastes.

---

## 1. Environment facts (what the skill must know)

| | **dev** | **prod** |
|---|---|---|
| Tenant | Joe's own M365 tenant (global admin) | Corporate tenant, different org |
| PnP PowerShell | Yes, app-only cert auth | No |
| `pac` CLI | Yes | No |
| Browser automation | Playwright, persistent profile | Human only |
| Script execution on SP | Harness page (PnPjs) + PnP PS | Harness page (PnPjs) only; browser console |
| Agent | Claude Code (this skill) | GitHub Copilot (VS Code + CLI), tight premium budget → default to GPT-4.1 / Haiku tier |
| Git | Full | `git clone` / `git pull` from public HTTPS only; **no push** |
| Data egress | Normal | **JSFiddle only** (paste JSON blobs/scripts) |
| Data ingress | Normal | Public GitHub clone; OneDrive sync folder |
| Power Platform | Export/unpack solutions to repo | Manual import in maker portal; **no premium** → connection refs re-bound by hand on every import |
| Page hosting | Modern page + Script Editor Web Part (SEWP) loading a script from a library | Same |

Standing conventions (carry into the skill verbatim):
- Dev site structure mirrors prod logically: same list/library/page/flow names. The tenant root AND the per-tenant library root paths differ (they are not identical relative URLs) — resolution goes through tenants.local.json / env.local.json via the shared resolver, never through echoed paths.
- List names and flow names match exactly across environments so connection/variable rebinding is mechanical.
- PnPjs custom bundle: `window.pnp2.sp`, requires `sp.setup({ sp: { baseUrl: _spPageContextInfo.webAbsoluteUrl } })`.
- Shipped SP code: no ES module imports. Build steps allowed but kept simple.
- Deploys overwrite in place; low traffic, "try again" acceptable.
- Git bundle transport: `main.bundle` in synced folder, `inbox\` for contributor bundles, folder marked "Always keep on this device."
- Deploy metadata columns when using `push` mode: `BuildId`, `GitSha`, `DeployedBy`, `Note`.
- **No tenant/site URLs in any repo, ever.** Logical names only.

---

## 2. Layout

```
~/.claude/skills/sp-env/                 # GLOBAL skill, dev machine only
  SKILL.md                               # rules (section 0), env facts, runbook index
  tenants.local.json                     # dev + prod site URLs, library roots (never copied to repo)
  auth/                                  # cert thumbprint / client id pointer (not the cert)
  runbooks/*.md                          # one page each: what it does, how to call it, how it verifies
  templates/                             # env.json, env.local.example.json, harness page, copilot-instructions

<repo>/
  env.json                               # logical names: lists, libraries, pages, flows, deploy mode
  env.local.json                         # GITIGNORED — site URLs + OneDrive mirror paths for THIS machine
  env.local.example.json                 # committed
  tools/sp/                              # scripts (PS + JS), all read env.json + env.local.json
    provision.js                         # PnPjs: lists, columns, libraries, pages-from-template
    verify.js                            # PnPjs: drift report vs env.json
    harness.html                         # SEWP-hosted runner: loads a script from libraries.scripts, posts results to TestRuns
    deploy.ps1                           # mode = copy | push | sync-live
    reset-dev.ps1                        # PnP PS: tear down everything in env.json, re-provision
    auth-refresh.ps1                     # PnP PS cert connect test + Playwright profile login check
    run-harness.js                       # Playwright: open harness page, run named script, read TestRuns
    pp-export.ps1                        # pac: export + unpack solution into /solution
  tests/                                 # Playwright specs (dev only)
  solution/                              # unpacked Power Platform solution (if any)
  .claude/skills/sp-project/SKILL.md     # THIN: "read env.json; use tools/sp; rules in global sp-env"
  .github/copilot-instructions.md        # GENERATED for prod; short; script-driven
```

---

## 3. `env.json` schema (logical names only)

```json
{
  "project": "example-app",
  "site": "primary",
  "libraries": {
    "scripts": { "root": "code", "path": "apps/example-app" },
    "data": { "root": "code", "path": "apps/example-app/data" }
  },
  "lists": {
    "items": { "title": "Example Items", "columns": [
      { "name": "Status", "type": "Choice", "choices": ["Open","Closed"] },
      { "name": "Owner", "type": "User" }
    ]},
    "testRuns": { "title": "TestRuns", "columns": [
      { "name": "Suite", "type": "Text" },
      { "name": "Passed", "type": "Boolean" },
      { "name": "Results", "type": "Note" },
      { "name": "GitSha", "type": "Text" }
    ]}
  },
  "pages": {
    "template": "SitePages/_app-template.aspx",
    "app":      { "name": "SitePages/example-app.aspx", "loader": "loader.js" },
    "harness":  { "name": "SitePages/_harness.aspx" }
  },
  "flows": ["Example Items - Notify Owner"],
  "deploy": { "mode": "copy" }
}
```

`env.local.json` (gitignored) adds per machine: `{ "env": "dev" | "prod", "siteUrl": "...", "roots": { ... }, "mirrors": { "code": "...", "devTools": "..." } }`. On machines with the global skill (dev), `tenants.local.json` is authoritative — omit `siteUrl`/`roots`/`mirrors` there (a conflicting value is an error). On machines without it (prod), `siteUrl` and `roots` are required. Logical roots (`code`, `devTools`, `lib`, `sitePages`) map to per-tenant paths; the shared resolver (`skill/scripts/resolve.js`) is the only code that performs this mapping.

---

## 4. Runbooks

| Runbook | Dev | Prod | Notes |
|---|---|---|---|
| `setup-dev-auth` | one-time | — | Register Entra app, cert, `Connect-PnPOnline -ClientId -Thumbprint -Tenant`; create Playwright persistent profile with one interactive login |
| `auth-refresh` | auto | — | Cert connect smoke + Playwright profile check; re-login only if profile is dead |
| `provision` | Playwright drives harness | human runs harness | Single PnPjs codepath. Idempotent. Copies template page → app page, rewrites SEWP `src` |
| `verify` | Playwright drives harness | human runs harness | Drift report: missing/extra lists, columns, libraries, pages, flow names present in solution |
| `reset-dev` | PnP PS | — | Delete everything in env.json, then `provision`, then `verify` |
| `deploy` | any mode | `copy` or `push` | `copy`: Copy-Item into `oneDriveMirror`. `push`: browser uploader stamps metadata. `sync-live`: existing pipeline |
| `test` | Playwright | human | Runs named suites via harness, results land in `TestRuns`; dev reads back via REST |
| `export-results` | — | human | Harness "copy results" button → JSON blob → JSFiddle |
| `page-from-template` | via provision | via provision | Standalone entry point for adding a page later |
| `pp-export` | pac | — | `pac solution export` + `unpack` into `/solution`, commit |
| `pp-import` | — | human | Doc-only runbook: import in maker portal, rebind connections using exact-name matching |
| `prod-update` | — | Copilot | `git pull`, `deploy -mode copy`, remind human to run `verify` + `test` harness |

---

## 5. Prod (Copilot) instructions — generated, kept tiny

- You are on the prod tenant. No PnP PowerShell, no pac, no git push, no external egress except the human pasting to JSFiddle.
- Do not reason about SharePoint. Run `tools/sp/deploy.ps1`, then tell the human which harness page to open and which button to click.
- Results come back as pasted JSON from `TestRuns`; summarize, don't re-derive.
- Prefer the cheapest model tier; escalate only for build failures.

Check whether BMO's Copilot picks up `.claude/skills/` (Copilot added Agent Skills support). If yes, the generated file collapses into the thin project skill.

---

## 6. Handoff prompt for Claude Code

```
You are building a reusable two-tenant SharePoint dev/prod tooling system for me.
Read the attached plan (sp-two-tenant-handoff.md) in full before doing anything.

HARD RULE (section 0): on dev, YOU verify every SharePoint change in a live browser
via Playwright and read results back from the TestRuns list or REST. Never end a
task by asking me to open a page, check a session, or confirm something in the
browser. If auth is stale, run auth-refresh and retry; if tooling can't do a step,
fix the tooling or report the exact failure.

Deliverables, in order. Stop after each phase and show me what you built plus the
live verification output.

Phase 1 — Global skill + auth
  - Create ~/.claude/skills/sp-env/ per section 2 with SKILL.md (section 0 rules,
    section 1 table, conventions, runbook index) and templates/.
  - tenants.local.json: I'll paste dev + prod URLs when you ask; never write these
    anywhere inside a repo.
  - setup-dev-auth runbook: script the Entra app registration (cert-based) for
    PnP PS app-only access, and create a Playwright persistent profile
    (launchPersistentContext). Prove both work: Connect-PnPOnline non-interactive,
    then open the dev site root in Playwright and read the page title.

Phase 2 — Pilot repo + provisioner + harness
  - Scaffold a small new pilot repo (not DCSPad) with env.json, env.local.json,
    .gitignore, tools/sp/, tests/, thin .claude/skills/sp-project.
  - Build harness.html (SEWP-hosted) that loads a named script from
    libraries.scripts, runs it, and posts {Suite, Passed, Results, GitSha} to
    TestRuns. Include a "copy results JSON" button for prod.
  - Build provision.js (idempotent: lists, columns, libraries, template page copy
    with SEWP src rewrite) and verify.js (drift report).
  - Build run-harness.js (Playwright) and reset-dev.ps1.
  - Verify: reset-dev → provision → verify shows zero drift → open app page in
    Playwright and confirm the SEWP loaded the loader script. Show me the
    TestRuns rows you read back.

Phase 3 — Deploy modes
  - deploy.ps1 with modes copy | push | sync-live. Implement copy fully and push
    (browser uploader with metadata columns, driven by Playwright on dev).
    Stub sync-live to call my existing Sync-Live.ps1 pattern.
  - Verify by deploying a changed loader.js in copy mode, waiting for sync, and
    confirming via REST that the file's Modified time updated.

Phase 4 — Prod instructions
  - Generate .github/copilot-instructions.md per section 5. Keep it under 40 lines.
  - Write the pp-import and export-results runbooks as human-readable docs.
  - Investigate whether Copilot reads .claude/skills; report findings.

Phase 5 — Power Platform (dev)
  - pp-export.ps1 using pac (export + unpack into /solution). Verify by exporting
    a throwaway solution containing one flow and one list reference and committing.

Constraints: no ES module imports in shipped SP code; PnPjs via window.pnp2 with the
setup() line; keep build steps minimal; every script reads env.json + env.local.json
and refuses to run if env.local.json is missing.
```

---
name: sp-env
description: Two-tenant SharePoint dev/prod environment facts, rules, and runbooks. Read this before any SharePoint work in any repo. Resolves logical names to URLs via tenants.local.json.
---

# sp-env — SharePoint two-tenant dev/prod environment

Global skill for all SharePoint projects on this machine. Repos carry only a thin
pointer skill (`.claude/skills/sp-project`) plus their own `env.json` manifest.
Canonical source: the `skill/` directory of the sp-development-handoff-process
repo; installed to `~/.claude/skills/sp-env` by its `install.ps1`.

## 0. The one rule (dev side) — HARD RULE

**On dev, Claude Code verifies outcomes itself in a live browser. It never hands
verification to the human.**

"Done" for any dev task that touches SharePoint means ALL of the following happened
in the same session:

1. The change was applied (PnP PowerShell or PnPjs via harness page).
2. `verify` was run and reported no drift.
3. The relevant page was opened in Playwright (persistent auth profile), the
   harness/test ran, and the results were read back from the `TestRuns` list or
   REST — by Claude Code, not by the user.
4. If the browser session is stale, run `auth-refresh` and retry; if that fails,
   report the failure with the exact error, not "next step: check your auth."

**Scope note:** steps 2–3 presume the harness/TestRuns machinery (Phase 2+). For
tasks where it doesn't apply — auth setup, tooling changes, read-only diagnostics —
the same principle holds with the available instruments: verification is a live
REST call or browser probe whose results Claude Code reads back itself. The only
sanctioned human steps are credential entry: initial/refresh Microsoft sign-ins
and admin consent.

**Forbidden output patterns on dev:** "next, you should open…", "please confirm in
the browser that…", "check whether the session is authenticated…". If the tooling
can't do it, the tooling is the bug — fix or report the tooling.

Prod is the opposite: the human runs the harness page; the agent only prepares
scripts and reads back what the human pastes (via the JSFiddle bridge).

## 1. Environment facts

| | **dev** | **prod** |
|---|---|---|
| Tenant | Personal dev M365 tenant (user is global admin) | Corporate tenant, different org |
| PnP PowerShell | Yes — app-only cert auth, **Sites.Selected** scoped to the dev site (pointer in `auth/dev-auth.local.json`; non-exportable key in `Cert:\CurrentUser\My`) | No |
| `pac` CLI | Yes | No |
| Browser automation | Playwright, persistent profile at `auth/pw-profile` | Human only |
| Script execution on SP | Harness page (PnPjs) + PnP PS | Harness page (PnPjs) only; browser console |
| Agent | Claude Code (this skill) | GitHub Copilot (VS Code + CLI), tight budget → cheapest model tier |
| Git | Full | `git clone` / `git pull` from public HTTPS only; **no push** |
| Data egress | Normal | **JSFiddle only** (human pastes JSON blobs/scripts) |
| Data ingress | Normal | Public GitHub clone; OneDrive sync folder |
| Power Platform | Export/unpack solutions to repo (`pac`) | Manual import in maker portal; no premium → connection refs re-bound by hand |
| Page hosting | Modern page + Script Editor Web Part (SEWP) loading a script from a library | Same |

**Where machine facts live (never in a repo or committed file):**
- `tenants.local.json` (next to this file, dev machines only) — tenant roots, site
  URLs, per-tenant library roots, Power Platform env, mirror paths. Where present
  it is **authoritative**.
- Repo `env.local.json` (gitignored) — selects `env` for that checkout. On
  machines **without** this global skill (prod), it must also supply `siteUrl` and
  `roots`. If both sources define a value and they disagree, tools **error out** —
  they never guess.

**Environment identity rule: the SITE URL defines dev vs prod. Folder/library names
(`Code`, `Dev`, `code`, `dev`) do NOT indicate environment — both tenants have both.**
`code`-root libraries hold would-be-production code and shared repos (bsp-design,
fluent-icons, framework libs under the `lib` root). `devTools`-root libraries hold
development tooling (e.g. DCSpad). **Library roots are NOT the same relative path on
both tenants** — always resolve through the resolver, never by echoing a dev path.

## 2. Standing conventions

- Names match across environments: the same **list titles, page names, library
  names within a root, and flow names** on both tenants, so connection/variable
  rebinding on prod import is mechanical lookup. What differs per tenant is the
  site URL and the **library root paths** — both resolved via `tenants.local.json`.
- PnPjs custom bundle: `window.pnp2.sp`; always call
  `sp.setup({ sp: { baseUrl: _spPageContextInfo.webAbsoluteUrl } })` first.
- Shipped SP code: **no ES module imports**. Build steps allowed but minimal.
- Deploys overwrite in place; low traffic, "try again" is acceptable.
- Git bundle transport for offline contributors: `main.bundle` in the synced folder,
  `inbox\` for contributor bundles, folder marked "Always keep on this device."
- `push`-mode deploy metadata columns: `BuildId`, `GitSha`, `DeployedBy`, `Note`.
- Every repo script reads `env.json` (logical names) + `env.local.json` (gitignored)
  and **refuses to run if `env.local.json` is missing**.
- Results are data, not screenshots: tests post to the `TestRuns` list; dev reads it
  via REST; prod serializes it to JSON for the JSFiddle bridge.

## 3. Name resolution — one algorithm

Committed manifests contain **only logical names**. `scripts/resolve.js` is the
single implementation (module + CLI: `node resolve.js <repoDir>`); all tools use
it. Tested by `scripts/test-resolve.js`.

1. `env` comes from repo `env.local.json` (`"dev"` | `"prod"`; required).
2. `env.json` `"site"` is the alias `"primary"`, resolved to
   `tenants.local.json[env].siteUrl` where the global skill exists; otherwise
   `env.local.json.siteUrl`. Both present and different → error.
3. Library/page entries name a root logically:
   `{ "root": "code" | "devTools" | "lib" | "sitePages", "path": "apps/x" }`
   (pages default to root `sitePages`). Roots map to per-tenant paths via
   `tenants.local.json[env].roots` (or `env.local.json.roots` on prod machines).
4. Manifest paths must be safe relative paths — URLs, drive letters, leading
   slashes, backslashes, `..` (including encoded), and unknown roots are rejected.
5. Mirror paths come from global `mirrors` (per root), overridable in
   `env.local.json.mirrors`.
6. Every resolved URL must remain inside the selected environment's site.

## 4. Runbooks

Index in `runbooks/INDEX.md`; one page per runbook. Scripts in `scripts/` here
(machine-level: auth, resolver) and in each repo's `tools/sp/` (project-level:
provision, verify, deploy, test, reset-dev, run-harness, pp-export).

Available now: `setup-dev-auth` (one-time; `-Rotate` to re-key), `auth-refresh`
(run whenever auth is stale, then retry the failed step).

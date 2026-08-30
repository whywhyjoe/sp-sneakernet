# Runbook index

Machine-level runbooks live here with scripts in `../scripts/`. Project-level
runbooks ship in each repo's `tools/sp/` (built from the templates in Phase 2+).

| Runbook | Dev | Prod | Status | Notes |
|---|---|---|---|---|
| `setup-dev-auth` | one-time / `-Rotate` | — | **available** | Entra app (cert, app-only, Sites.Selected on dev site) for PnP PS + Playwright persistent profile. [setup-dev-auth.md](setup-dev-auth.md) |
| `auth-refresh` | auto | — | **available** | Cert connect smoke + classified Playwright profile check; headed re-login only on auth_stale. [auth-refresh.md](auth-refresh.md) |
| `resolve` | any tool | any tool | **available** | `scripts/resolve.js` — the one logical-name→URL/mirror algorithm; tests in `test-resolve.js` |
| `scaffold-project` | one per project | — | **available** | Stamps a new repo from templates/project. [scaffold-project.md](scaffold-project.md) |
| `provision` | Playwright drives harness | human runs harness | **available** (template) | Single PnPjs codepath, idempotent; template page → app page with SEWP token rewrite |
| `verify` | Playwright drives harness | human runs harness | **available** (template) | Drift report vs env.json; passed = zero drift |
| `bootstrap-dev` | PnP PS, once | human (manual page) | **available** (template) | Ensures TestRuns + harness page from template page |
| `reset-dev` | PnP PS | — | **available** (template) | Delete everything in env.json (needs -Force), then deploy → bootstrap → provision → verify |
| `deploy` | `copy` / `push` (Playwright) / `-DirectUpload` | `copy` / `push` (human runs upload op) | **copy + push available**; sync-live = stub (drop in Sync-Live.ps1) | copy = mirror write incl. resolved-env.json + GitSha; push = harness upload op stamping BuildId/GitSha/DeployedBy/Note (columns auto-ensured) |
| `test` | Playwright (`run-harness.js`) | human runs harness | **available** (template) | Named ops via harness → TestRuns; dev reads back via REST |
| `export-results` | — | human | **available** | Harness "copy results" button → JSON → JSFiddle. [export-results.md](export-results.md) |
| `page-from-template` | via provision | via provision | phase 2 | Standalone entry point for adding a page later |
| `pp-export` | pac | — | **available** (template) | `tools/sp/pp-export.ps1`: pac export + unpack into /solution, commit; `-List` to enumerate. **Flows only** — solutions exist here solely for flow versioning; canvas apps ship as .zip/.msapp (see SKILL.md canvas section). pac = dotnet global tool; env GUID in tenants.local.json powerPlatform |
| `pp-import` | — | human | **available** | Flows-only solution import in maker portal, rebind connections by exact-name match. [pp-import.md](pp-import.md) |
| `prod-update` | — | Copilot | **available** | Encoded in the generated `.github/copilot-instructions.md` (scaffold stamps it): `git pull`, deploy, human runs harness, paste results. Copilot also reads `.claude/skills` — see [copilot-agent-skills-findings.md](copilot-agent-skills-findings.md) |

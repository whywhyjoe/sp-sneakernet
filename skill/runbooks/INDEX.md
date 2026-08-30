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
| `deploy` | `copy` | `copy` | **copy available**; push/sync-live phase 3 | copy = mirror write incl. resolved-env.json + GitSha; push = browser uploader stamping BuildId/GitSha/DeployedBy/Note |
| `test` | Playwright (`run-harness.js`) | human runs harness | **available** (template) | Named ops via harness → TestRuns; dev reads back via REST |
| `export-results` | — | human | phase 4 | Harness "copy results" button → JSON → JSFiddle |
| `page-from-template` | via provision | via provision | phase 2 | Standalone entry point for adding a page later |
| `pp-export` | pac | — | phase 5 | `pac solution export` + unpack into /solution, commit. **Flows only** — solutions exist here solely for flow versioning; canvas apps ship as .zip/.msapp (see SKILL.md canvas section) |
| `pp-import` | — | human | phase 4 | Doc-only: import in maker portal, rebind connections by exact-name match |
| `prod-update` | — | Copilot | phase 4 | `git pull`, deploy copy mode, remind human to run verify + test harness |

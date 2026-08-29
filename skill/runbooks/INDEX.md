# Runbook index

Machine-level runbooks live here with scripts in `../scripts/`. Project-level
runbooks ship in each repo's `tools/sp/` (built from the templates in Phase 2+).

| Runbook | Dev | Prod | Status | Notes |
|---|---|---|---|---|
| `setup-dev-auth` | one-time / `-Rotate` | — | **available** | Entra app (cert, app-only, Sites.Selected on dev site) for PnP PS + Playwright persistent profile. [setup-dev-auth.md](setup-dev-auth.md) |
| `auth-refresh` | auto | — | **available** | Cert connect smoke + classified Playwright profile check; headed re-login only on auth_stale. [auth-refresh.md](auth-refresh.md) |
| `resolve` | any tool | any tool | **available** | `scripts/resolve.js` — the one logical-name→URL/mirror algorithm; tests in `test-resolve.js` |
| `provision` | Playwright drives harness | human runs harness | phase 2 | Single PnPjs codepath, idempotent; template page → app page with SEWP src rewrite |
| `verify` | Playwright drives harness | human runs harness | phase 2 | Drift report vs env.json |
| `reset-dev` | PnP PS | — | phase 2 | Delete everything in env.json, then provision, then verify |
| `deploy` | any mode | `copy` or `push` | phase 3 | copy = Copy-Item into mirror; push = browser uploader stamping BuildId/GitSha/DeployedBy/Note; sync-live = full pipeline |
| `test` | Playwright | human | phase 2 | Named suites via harness → TestRuns; dev reads back via REST |
| `export-results` | — | human | phase 4 | Harness "copy results" button → JSON → JSFiddle |
| `page-from-template` | via provision | via provision | phase 2 | Standalone entry point for adding a page later |
| `pp-export` | pac | — | phase 5 | `pac solution export` + unpack into /solution, commit |
| `pp-import` | — | human | phase 4 | Doc-only: import in maker portal, rebind connections by exact-name match |
| `prod-update` | — | Copilot | phase 4 | `git pull`, deploy copy mode, remind human to run verify + test harness |

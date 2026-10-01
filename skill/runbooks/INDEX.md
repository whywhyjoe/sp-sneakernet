# Runbook index

All runbook DOCS live here (with machine-level scripts in `../scripts/`).
Project-level SCRIPTS ship in each repo's `tools/sp/`, stamped from
`../templates/project/` by scaffold-project; their usage is documented in the
rows below and in each script's comment header.

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
| `export-results` | — | human + `send-to-dev.js` | **available** | Results JSON, an uncommitted diff, or whole files → `tools/sp/send-to-dev.js` checks + prefills JSFiddle → human reviews, Ctrl+S, sends URL. [export-results.md](export-results.md) |
| `import-from-jsfiddle` | agent | — | **available** | Dev reads the fiddle back (`jsfiddle-fetch.py` + `jsfiddle-unpack.py` in the sneakernet repo, `localRepos.sneakernet`): results → report; diff → git apply; files → byte-exact, hash-verified; then the normal dev loop. Private fiddles are read signed in through the push login profile, automatically. [import-from-jsfiddle.md](import-from-jsfiddle.md) |
| `push-to-jsfiddle` | agent | — | **available** | Dev creates/updates a fiddle (`jsfiddle-push.py`; login via a dedicated Edge profile, human signs in once): drop-box fiddles for prod, one-off snippets. Public — no tenant facts. [push-to-jsfiddle.md](push-to-jsfiddle.md) |
| `page-from-template` | via provision | via provision | phase 2 | Standalone entry point for adding a page later |
| `pp-export` | human (maker portal) | — | **available** (manual) | **No solutions** (2026-10-01). Flow: My flows → ⋯ → Export → **Package (.zip)** → `packages/<name>_<FlowVersion>.zip`, SHA-256 appended to `packages/CHECKSUMS.txt`, commit, tag. Canvas apps: package .zip + .msapp (see SKILL.md canvas section). The old `tools/sp/pp-export.ps1` (pac solution export) is **retired** — delete it from any repo that still has it |
| `pp-import` | — | human | **available** | Flow legacy-package import: My flows → Import → **Import Package (Legacy)**, rebind connections by hand (exact-name match), verify `FlowVersion`. [pp-import.md](pp-import.md) |
| `prod-update` | — | Copilot | **available** | Encoded in the generated `.github/copilot-instructions.md` (scaffold stamps it): `git pull`, deploy, human runs harness, paste results. Copilot also reads `.claude/skills` — see [copilot-agent-skills-findings.md](copilot-agent-skills-findings.md) |

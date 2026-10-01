# pp-import (prod, human) — import a flow package and rebind connections

**No solutions** (decided 2026-10-01). A flow travels as a legacy flow
**Package (.zip)** and is imported under **My flows**, never into a solution —
even when the flow it replaces lives in one. Git, `packages/` and tags are the
version history. Canvas apps ship as package .zip / .msapp — see the canvas
section of SKILL.md.

**You need:** the package committed at `packages/<name>_<FlowVersion>.zip`
with its SHA-256 line in `packages/CHECKSUMS.txt` (dev exports it via My flows
→ ⋯ → Export → **Package (.zip)**; runbook row `pp-export`), and Environment
Maker on the prod environment. No premium licensing exists there —
**connections must be re-bound by hand on every import.**

## Steps

1. `git pull`, then verify the package against its checksum:
   `Get-FileHash -Algorithm SHA256 packages\<file>.zip` must match the line in
   `packages\CHECKSUMS.txt`. Mismatch ⇒ stop; do not import.
2. make.powerautomate.com (prod) → correct environment → **My flows → Import →
   Import Package (Legacy)** → **Upload** → the .zip.
3. **Import setup** for the flow row → **Create as new** (keeps the previous
   version intact for rollback) → Save.
4. **Related resources:** for each connection row → **Select during
   import** → pick (or create, then Refresh list) the prod connection of the
   same connector type → Save. Consent prompts are normal on first use.
5. **Import** → wait for the success banner. Imported flows arrive **off**.
6. Open the new flow → re-point the site variable to prod's site if the flow
   takes it from one (lists are found by **title**, identical on both
   tenants). If a Power App calls this flow, re-attach it in the app.
7. Turn the **previous** version off, turn the new one **on**.
8. **Verify by exercising the trigger once** (e.g. save an item on the target
   list): a run appears in run history and its diagnostics show the expected
   **`FlowVersion`** — the package name's version. Tell the agent the outcome
   rather than assuming.
9. Keep the previous version (off) until the new one has run clean on real
   work; then delete it.

## Failure notes

- "Connection not configured" on a flow step → step 4 missed one; edit the
  flow, re-select the connection on the failing action, save.
- Missing list/column errors → the prod list drifted from dev. Fix the DEV
  list to match prod, re-test, re-export (flows follow prod's schema, never
  the reverse).
- Import Package (Legacy) needs third-party cookies enabled in the browser.

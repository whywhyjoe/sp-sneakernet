# pp-import (prod, human) — import a flow solution and rebind connections

Solutions are used for **flows only** (they exist solely to get flow
versioning). Canvas apps ship as package .zip / .msapp instead — see the
canvas section of SKILL.md.

**You need:** the exported solution .zip (unmanaged) committed at
`packages/<SolutionName>_<version>.zip` — pp-export writes it there
specifically because prod has no pac and cannot re-pack the unpacked
`/solution` tree — and maker-portal access on the prod environment. No premium
licensing exists there — **connection references must be re-bound by hand on
every import.**

## Steps

1. make.powerapps.com (prod) → correct environment → **Solutions → Import
   solution** → browse to the .zip → Next.
2. **Connections page:** for each connection reference, select (or create) the
   prod-tenant connection of the same connector type. Consent prompts are
   normal on first use.
3. **Environment variables page** (if any): fill prod values — site URL and
   list names. List and flow names are IDENTICAL across tenants by convention,
   so every binding is an exact-name lookup, never a guess.
4. Import → wait for the success banner. Open each flow → check it is **On**;
   turn on if not.
5. **Verify by exercising the trigger once** (e.g. save an item on the target
   list) and confirming a run appears in the flow's run history — then tell
   the agent the outcome rather than assuming.

## Failure notes

- "Connection not configured" on a flow step → the rebinding in step 2 missed
  one; edit the flow, re-select the connection on the failing action, save.
- Missing list/column errors → the prod list drifted from dev. Fix the DEV
  list to match prod, re-test, re-export (the app/flows follow prod's schema,
  never the reverse).

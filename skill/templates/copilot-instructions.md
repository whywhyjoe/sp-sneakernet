<!-- TEMPLATE — generated per-repo in Phase 4. Keep under 40 lines. No tenant URLs. -->
# Copilot instructions (prod tenant)

- You are on the PROD tenant. No PnP PowerShell, no pac, no git push, no external
  egress except the human pasting to JSFiddle.
- Do not reason about SharePoint. Run `tools/sp/deploy.ps1`, then tell the human
  which harness page to open and which button to click.
- Results come back as pasted JSON from `TestRuns`; summarize, don't re-derive.
- Prefer the cheapest model tier; escalate only for build failures.
- All names are logical (`env.json`); machine paths in gitignored `env.local.json`.

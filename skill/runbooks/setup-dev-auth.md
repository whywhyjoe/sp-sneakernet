# setup-dev-auth (one-time, dev machine; `-Rotate` to re-key; `-Audit` to verify)

**Two-app model:**
- **Workload app** (`sp-env-dev-agent-<ts>`) — application permissions ONLY
  (SharePoint `Sites.Selected` + Graph `Sites.Selected`), certificate credential,
  FullControl granted on the dev site only. Never used interactively; carries no
  delegated scopes at all.
- **Bootstrap admin app** (`sp-env-admin-bootstrap`) — delegated permissions ONLY
  (Graph `Application.ReadWrite.All`, `Sites.FullControl.All`,
  `DelegatedPermissionGrant.ReadWrite.All`; SharePoint `AllSites.FullControl`),
  no credentials. Powers interactive admin sessions (key upload, site grants,
  retirement, audit) and is useless without a live admin sign-in.

**Key security properties:**
- The workload certificate is created directly in `Cert:\CurrentUser\My` with a
  **non-exportable** private key; **no PFX/CER file is ever written to disk**
  (`-SkipCertCreation`; public key uploaded via Graph). Registration runs from a
  scratch temp dir (regression test: `test-setup-clean.ps1`, file-set + content-hash).
- Pointers (no secrets): `auth/dev-auth.local.json` (workload),
  `auth/bootstrap-app.local.json`, plus transient `pending-app.local.json`
  (interrupted registration resumes the same app) and `retire-app.local.json`
  (a rotation records the outgoing app BEFORE the pointer switch; the run FAILS
  if deletion cannot be verified, and the next run completes retirement first —
  the old certificate is removed only after the app is confirmed gone).

**Idempotence = enforced invariants, not existence.** Health checks: pointer
completeness + `scope=Sites.Selected`, cert in store with private key,
`ExportPolicy=None`, >30 days validity, live app-only connect. `-Audit` adds the
deep checks via a bootstrap session: app object matches the pointer, our
thumbprint among its keyCredentials, application permissions restricted to the
Sites.Selected allowlist, **zero delegated scopes** (legacy ones are stripped and
their consent grants revoked automatically), and exactly one FullControl site
grant (roles queried explicitly — an interrupted Write→FullControl elevation is
detected and completed).

**How to call:**
```powershell
pwsh -File ~/.claude/skills/sp-env/scripts/setup-dev-auth.ps1              # health-check + repair as needed
pwsh -File ~/.claude/skills/sp-env/scripts/setup-dev-auth.ps1 -Audit      # + deep security audit (interactive)
pwsh -File ~/.claude/skills/sp-env/scripts/setup-dev-auth.ps1 -Rotate     # force new workload app + cert
pwsh -File ~/.claude/skills/sp-env/scripts/setup-dev-auth.ps1 -DeviceLogin # device-code registration sign-ins
# -SkipEntra fails hard if no healthy credential; -SkipPlaywright skips the profile step
```

**How it verifies:** `PNP-OK Title=… Url=…` from a non-interactive cert connect
(propagation-signature retries only right after registration), `RETIRE-OK` only
after the old app is confirmed absent, `AUDIT-OK` with the invariant summary,
and `PW-PROFILE-OK {…}` from a live in-page REST probe. Anything else is a
failure to report.

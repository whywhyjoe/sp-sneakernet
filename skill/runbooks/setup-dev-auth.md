# setup-dev-auth (one-time, dev machine; `-Rotate` to re-key)

**What it does:** registers an Entra app for PnP PowerShell app-only auth with
**Sites.Selected** application permission and a **FullControl grant on the dev
site only** (not tenant-wide), then creates/repairs the Playwright persistent
browser profile at `../auth/pw-profile`.

**Key security properties:**
- The certificate is created directly in `Cert:\CurrentUser\My` with a
  **non-exportable** private key; **no PFX/CER file is ever written to disk**
  (registration uses `-SkipCertCreation`; the public key is uploaded via Graph).
- Registration runs from a scratch temp dir, so nothing can be dropped into the
  caller's working directory (regression test: `test-setup-clean.ps1`).
- Pointer saved to `../auth/dev-auth.local.json`: clientId, objectId, thumbprint,
  tenant, appName, scope — no secrets.

**Idempotence = health, not existence.** Re-running checks: pointer completeness,
cert in store, private key present, >30 days to expiry, and a live app-only
connect. Only if any check fails (or `-Rotate` is passed) does it register a fresh
app + cert, and it retires the previous app and cert **after** the new credential
is proven.

**Human-present moments:** the registration/consent sign-in and (first time or
when stale) the Playwright profile login. Everything else is non-interactive.

**How to call:**
```powershell
pwsh -File ~/.claude/skills/sp-env/scripts/setup-dev-auth.ps1              # health-check + repair as needed
pwsh -File ~/.claude/skills/sp-env/scripts/setup-dev-auth.ps1 -Rotate     # force new app + cert, retire old
pwsh -File ~/.claude/skills/sp-env/scripts/setup-dev-auth.ps1 -DeviceLogin # device-code flow for registration
# -SkipEntra fails hard if no healthy credential exists; -SkipPlaywright skips the profile step
```

**How it verifies:** non-interactive `Connect-PnPOnline` (cert) + `Get-PnPWeb`
prints `PNP-OK Title=… Url=…` — with a retry loop only right after a fresh
registration, and only for consent-propagation-signature errors; other errors
fail fast. The profile script prints `PW-PROFILE-OK {…}` from a live in-page REST
probe. Anything else is a failure to report.

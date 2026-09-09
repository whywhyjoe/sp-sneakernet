---
name: sp-env
description: Two-tenant SharePoint dev/prod environment facts, rules, and runbooks. Read this before any SharePoint work in any repo. Resolves logical names to URLs via tenants.local.json.
---

# sp-env — SharePoint two-tenant dev/prod environment

Global skill for all SharePoint projects on this machine. Repos carry only a thin
pointer skill (`.claude/skills/sp-project`) plus their own `env.json` manifest.
Canonical source: the `skill/` directory of the sp-sneakernet
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

**OneDrive mirrors — facts and hard limits:**
- The mirror paths (see `mirrors` in `tenants.local.json`) are **intentional
  reparse points** (junctions into the OneDrive sync folder) so the local path
  is IDENTICAL on every dev and prod machine. A mirror being a reparse point is
  EXPECTED — it is not an anomaly to investigate or "fix".
- If deployed files never appear in the library: **first check that OneDrive is
  actually running** (`Get-Process OneDrive`). Allowed diagnostics, all
  read-only: is the process up; does the reparse point resolve to a real
  location; do the files exist at the target; has the file arrived in the
  library (REST check on the file URL).
- **FORBIDDEN, always:** creating new folders inside OneDrive, changing or
  re-linking sync locations, moving the reparse point, or restructuring
  anything to "repair" sync. If sync is broken beyond "OneDrive isn't
  running", STOP and tell the user exactly what you observed — sync
  configuration is theirs alone.

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
- PnPjs custom bundle: `lib/pnp2.bundle.js` (UMD; sets `window.pnp2` and
  `window.pnp` for compat); always call `sp.setup({ sp: { baseUrl: … } })`
  first. **baseUrl:** `_spPageContextInfo` is NOT reliably present on modern
  pages — use `window._spPageContextInfo?.webAbsoluteUrl` with a fallback to
  the deployed `resolved-env.json` `siteUrl`.
- **Modern Script Editor web part** is installed on the dev site — componentId
  `3a328f0a-99c4-4b28-95ab-fe0847f657a3`. Its properties include an
  `spPageContextInfo` toggle (can inject `_spPageContextInfo` when true; our
  pattern keeps it false and uses the resolved-env fallback instead). Template
  pages can therefore be CREATED programmatically on dev (bootstrap-dev does
  this) — manual page prep is only needed on prod or where the web part is
  missing.
- **Verifier quality:** a verification step that can time out while the
  operation succeeded is a defect, same severity as a false pass. Example
  found live: Playwright's default wait is `visible`, but empty zero-size
  marker divs are never visible — wait for `state: 'attached'`.
- **AMD trap (proven empirically on this tenant):** modern SharePoint pages run
  an AMD loader, so a UMD bundle loaded by LATE dynamic injection
  (`document.createElement('script')`) registers as an anonymous AMD module and
  never sets `window.pnp2`. A literal `<script src=…>` inside SEWP markup runs
  early enough to be safe. When injecting the bundle dynamically, temporarily
  hide **`define.amd`** (delete it, load, restore it on success AND failure —
  not `define` itself) — the template `loader.js`/`harness.js` do this; keep
  the pattern.
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
4. Manifest paths AND configured roots must be safe relative paths — URLs, drive
   letters, leading slashes, backslashes, `..`, percent characters, control
   characters, `?`/`#`, and unknown roots are all rejected outright.
5. Mirror paths come from global `mirrors` (per root). Locals never override:
   where `tenants.local.json` exists, an explicit local root/mirror/siteUrl must
   match it exactly (blank = omitted); disagreements and unknown keys are errors.
   Locals supply these values only on machines without the global skill (prod).
6. Every resolved URL must remain inside the selected environment's site AND
   inside its selected root, checked after WHATWG URL normalization.

## 4. Starting a new project (the standard workflow)

**Scope:** this workflow is the default for a new PROJECT (an app with a repo,
lists, pages, and a test loop). It is not a straitjacket: for ad-hoc or
divergent asks — a one-off page, a quick list change, an experiment that
doesn't fit the template-page pattern — skip the scaffold and use whatever
approach fits (PnP PowerShell, REST, a hand-built page). Sections 0–3 still
bind EVERY task regardless: verify it yourself in a live browser (§0), pull
URLs only from tenants.local.json, reuse the existing auth (Connect-SpEnvDev /
pw-profile via `scripts/sp-env-common.ps1`), and keep shipped SP code
module-free with window.pnp2 + setup(). Never re-derive tooling that already
exists here; diverge from the workflow, not from the rules.

For a new project, do THIS:

1. **Scaffold**: `pwsh -File ~/.claude/skills/sp-env/scripts/scaffold-project.ps1
   -Path <repoDir> -Project <name>` — stamps env.json, `.gitignore`,
   `env.local.json` (dev), `tools/sp/` (deploy, bootstrap-dev, reset-dev,
   run-harness, resolver copy), `app/` (harness.js + provision/verify/test ops,
   loader.js + app.js), and the thin `.claude/skills/sp-project` pointer.
2. **Edit `env.json`** to the project's real needs: lists + columns (+ optional
   `seed` rows), pages, deploy mode. Logical names only. Check
   `libraries.pnp2.path` matches the actual pnp2 bundle filename in the shared
   `lib` root (inspect the library if unsure).
3. **Deploy**: `pwsh -File tools/sp/deploy.ps1` (copy mode → OneDrive mirror;
   allow sync latency — confirm arrival via REST, e.g. fetch harness.js URL).
   If sync is backed up (OneDrive running but slow), `-DirectUpload` uploads
   the artifacts via PnP with a SHA256 mirror-parity check — the mirror stays
   canonical and sync config is never touched.
4. **First time only — `pwsh -File tools/sp/bootstrap-dev.ps1`**: ensures
   TestRuns + the template page (`SitePages/_app-template.aspx` — auto-created
   with the Modern Script Editor web part if missing) + creates the harness
   page from it by rewriting the `__SP_ENV_SCRIPT__` token. Manual page prep is
   only needed if the web part isn't installed (the error says exactly what to
   create) or on prod.
5. **Provision / verify / test** (closed loop, per §0):
   `node tools/sp/run-harness.js provision` → `… verify` (must report zero
   drift) → `… test-smoke`. Each prints the harness result AND the latest
   TestRuns rows read back via REST. Then open the app page in Playwright and
   confirm it rendered (`#sp-env-app-root[data-sp-env-rendered]`).
6. **Iterate**: change app/, deploy, rerun the relevant op. `reset-dev.ps1
   -Force` for a clean slate. Auth stale at any point → `auth-refresh` → retry.

### BSP parts — opt-in pattern, NOT the default

Only when the user says they're building a **BSP part / BSP project**: follow
the guidance in the local `bsp-sp-parts` repo (path under `localRepos.bspParts`
in `tenants.local.json` — read its README first). It defines the four-artifact
web-part pattern (`<tool>.webpart.html` per-instance stub, shared `<tool>.js`
engine, `<tool>.css` on design-system tokens, per-instance `config.json`), the
`_shared/dcs-part-boot.js` boot contract (host-div wait, multi-instance mount,
edit-mode placeholder, SPA re-mount), and the portal runtime already live on
the site: BSP design system bundle, self-hosted `Code/lib/alpine.js`, and
`fcu-standard.js` (supplies `waitForElement`, `waitForPnP2`,
`dcsOnSpaNavigation`, `dcsRegisterAlpineComponent`, `__dcsIsEditMode` —
including the Alpine wait/registration patterns). Buildless, CDN-free at
runtime.

For everything else, DO NOT reach for the BSP pattern — the simple §4 scaffold
(or a plain divergent build) is the default. Sections 0–3 bind BSP work like
any other.

### Power Apps canvas work — operating rules (not design rules)

When working on a Power Apps **canvas app**, these operating facts apply without
being told. Deep reference: the IanI app repo (`localRepos.ianiApp` in
`tenants.local.json`), especially its `BUILD-AND-SHIP.md` — §4 (sync ritual) and
§7 (compiler/control/Studio lessons) are the hard-won parts. Nothing here
prescribes how an app is designed.

**Toolchain (assume it, don't ask):** Claude Code + the canvas-apps plugin's
**Canvas Authoring MCP** (`canvas-authoring`, local .NET 10 server; set up via
`/configure-canvas-mcp`). A **Power Apps Studio browser tab holds the live
coauthoring session** the MCP pushes into — it exists, stays open all session,
and is the user's window, not yours. Repo `.pa.yaml` is authoritative; the MCP
can only WRITE to the session scratchpad, so `sync_canvas` pulls land there and
get mirrored into the repo. The server canonicalizes YAML on ingest — adopt the
synced copy as the new baseline, don't fight it.

**THE SYNC RITUAL (version stamping + proof of delivery):**
- `App.Formulas` carries `* SYNC MARKER: push #N — <desc>`; **bump N on every
  push**; commit per push with the marker number in the message.
- Push flow: bump marker → `compile_canvas` (validates AND pushes) →
  `sync_canvas` to scratchpad → read the post-push marker there → mirror to repo.
- Proof is three-part: pre-push sync shows the USER's state, post-push sync
  shows the transition, and the user reads the new marker in Studio. Syncing
  back only from a session you just pushed into self-confirms — worthless.
- Marker mismatch ⇒ orphaned session (every Studio refresh orphans it):
  `connect` again, re-push. Still stuck ⇒ the session has FORKED (version
  restore does this; even `connect` can re-attach to the dead session) — the
  user must close the whole browser, reopen, then reconnect.
- A push is NOT durable until the user saves in Studio (Ctrl+S). `HTTP 401
  Invalid session state` ⇒ `connect` and retry.

**Studio gotchas (don't chase these as app bugs):** OnStart does not auto-run
in the editor — blank vars/"broken app" reports usually mean Run OnStart wasn't
clicked; judge pixels in Preview (F5), never the edit canvas (it ghost-renders
and lies); card/grid layout edits in the designer forcibly renumber the form —
position work happens in YAML via push, never the designer; SharePoint schema
changes need a Data-panel refresh before the session sees new columns.

**Versioning & shipping:** canvas apps do NOT use Dataverse solutions here.
Ship = export BOTH the canvas package (.zip, primary — its wizard remaps
connections) and .msapp, commit to `packages/` with SHA-256 checksums, name
`<App>_<cfgAppVer>_<push#>.<ext>` (that pair is the build number), git tag.
**Solutions are used ONLY for Power Automate flows** — forced, because that's
the only way to get flow versioning; that's what `pp-export` is for.

## 5. Runbooks

Index in `runbooks/INDEX.md`; one page per runbook. Scripts in `scripts/` here
(machine-level: auth, resolver, scaffold) and in each repo's `tools/sp/`
(project-level, stamped by scaffold).

Available now: `setup-dev-auth` (one-time; `-Rotate` to re-key; `-Audit`),
`auth-refresh` (run whenever auth is stale, then retry the failed step),
`scaffold-project`, and the stamped project runbooks (deploy copy mode,
bootstrap-dev, reset-dev, run-harness provision/verify/test).

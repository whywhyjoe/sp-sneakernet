<#
.SYNOPSIS
Installs the sp-env global skill from this repo's skill/ directory (the versioned
source of truth) into ~/.claude/skills/sp-env.

Order of operations (fail-fast; every native exit code checked):
  1. Source sanity: refuse if local/secret files are present in skill/.
  2. STAGE: copy source to a temp dir and validate there (JS syntax, PS parse,
     resolver tests) BEFORE touching the live installation.
  3. DEPLOY: copy the staged set over the target, then remove previously managed
     files that no longer exist in the source (tracked via installed-manifest.json),
     never touching local state (*.local.json, auth/, node_modules).
  4. npm ci in the target from the committed package-lock.json (reproducible).
  5. Final smoke: resolver tests in the installed location.
Idempotent; run after every git pull that touches skill/.
#>
[CmdletBinding()]
param(
    [string]$Target = (Join-Path $HOME '.claude\skills\sp-env')
)
$ErrorActionPreference = 'Stop'
$source = Join-Path $PSScriptRoot 'skill'
if (-not (Test-Path $source)) { throw "skill/ source not found at $source" }

function Assert-NativeOk([string]$What, [int[]]$OkCodes = @(0)) {
    if ($LASTEXITCODE -notin $OkCodes) { throw "$What failed with exit code $LASTEXITCODE" }
}

# ---------- 1. Source sanity ----------
$forbidden = Get-ChildItem $source -Recurse -Force -Include '*.local.json', '*.pfx', '*.cer', '*.pem', '*.key' -ErrorAction SilentlyContinue
if ($forbidden) { throw "Refusing to install: local/secret files present in skill/ source: $($forbidden.FullName -join ', ')" }
if (-not (Test-Path (Join-Path $source 'scripts\package-lock.json'))) { throw 'skill/scripts/package-lock.json missing — commit a lockfile (npm install --package-lock-only).' }

# ---------- 2. Stage + validate ----------
$stage = Join-Path ([System.IO.Path]::GetTempPath()) ("sp-env-stage-" + [guid]::NewGuid().ToString('n'))
try {
    robocopy $source $stage /E /NFL /NDL /NJH /NJS | Out-Null
    Assert-NativeOk 'robocopy (stage)' @(0, 1, 2, 3, 4, 5, 6, 7)

    Push-Location (Join-Path $stage 'scripts')
    try {
        foreach ($js in Get-ChildItem *.js) { node --check $js.FullName; Assert-NativeOk "node --check $($js.Name)" }
        foreach ($ps in Get-ChildItem *.ps1) {
            $errs = $null
            [System.Management.Automation.Language.Parser]::ParseFile($ps.FullName, [ref]$null, [ref]$errs) | Out-Null
            if ($errs) { throw "PowerShell parse errors in $($ps.Name): $($errs -join '; ')" }
        }
        node .\test-resolve.js | Select-Object -Last 1
        Assert-NativeOk 'resolver tests (stage)'
    } finally { Pop-Location }

    # ---------- 3. Deploy + prune obsolete managed files ----------
    New-Item -ItemType Directory -Path $Target -Force | Out-Null
    $manifestPath = Join-Path $Target 'installed-manifest.json'
    $oldManaged = if (Test-Path $manifestPath) { (Get-Content $manifestPath -Raw | ConvertFrom-Json).files } else { @() }

    robocopy $stage $Target /E /NFL /NDL /NJH /NJS | Out-Null
    Assert-NativeOk 'robocopy (deploy)' @(0, 1, 2, 3, 4, 5, 6, 7)

    $newManaged = Get-ChildItem $stage -Recurse -File | ForEach-Object { $_.FullName.Substring($stage.Length + 1) }
    $localStatePattern = '(^|\\)(auth|node_modules)(\\|$)|\.local\.json$'
    foreach ($rel in $oldManaged) {
        if ($rel -in $newManaged) { continue }
        if ($rel -match $localStatePattern -or $rel -eq 'installed-manifest.json') { continue }
        $stale = Join-Path $Target $rel
        if (Test-Path $stale) { Remove-Item $stale -Force; Write-Host "[install] Removed obsolete managed file: $rel" }
    }
    [pscustomobject]@{ installedUtc = (Get-Date).ToUniversalTime().ToString('o'); files = $newManaged } |
        ConvertTo-Json | Set-Content $manifestPath -Encoding utf8

    # ---------- 4. Reproducible dependencies ----------
    Push-Location (Join-Path $Target 'scripts')
    try {
        $lockHashPath = 'node_modules\.package-lock.hash'
        $lockHash = (Get-FileHash package-lock.json -Algorithm SHA256).Hash
        $needCi = -not (Test-Path 'node_modules\playwright') -or -not (Test-Path $lockHashPath) -or ((Get-Content $lockHashPath -Raw -ErrorAction SilentlyContinue) -ne $lockHash)
        if ($needCi) {
            npm ci --no-fund --no-audit | Out-Null
            Assert-NativeOk 'npm ci'
            Set-Content $lockHashPath $lockHash -NoNewline
        }
        # ---------- 5. Final smoke in the installed location ----------
        node .\test-resolve.js | Select-Object -Last 1
        Assert-NativeOk 'resolver tests (installed)'
    } finally { Pop-Location }
} finally {
    Remove-Item $stage -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host "INSTALL-OK sp-env installed to $Target — staged validation, managed-file prune, npm ci (locked), and installed-location tests all passed."

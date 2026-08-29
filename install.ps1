<#
.SYNOPSIS
Installs the sp-env global skill from this repo's skill/ directory (the versioned
source of truth) into ~/.claude/skills/sp-env.

Order of operations (fail-fast; every native exit code checked; the live
installation is NOT touched until ALL validation — including dependency
installation — has succeeded in the stage):
  1. Source sanity: refuse if local/secret files are present in skill/.
  2. STAGE: copy source to a temp dir; validate there (JS syntax, PS parse,
     resolver tests); if the committed package-lock.json differs from what the
     target has, run `npm ci` IN THE STAGE too.
  3. DEPLOY: copy the fully validated stage over the target, prune previously
     managed files that no longer exist in the source (tracked via
     installed-manifest.json, with strict path containment), preserve local
     state (*.local.json, auth/), and write the new manifest LAST.
  4. Final smoke: resolver tests in the installed location.
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
$RoboOk = @(0, 1, 2, 3, 4, 5, 6, 7)

# ---------- 1. Source sanity ----------
$forbidden = Get-ChildItem $source -Recurse -Force -Include '*.local.json', '*.pfx', '*.cer', '*.pem', '*.key' -ErrorAction SilentlyContinue
if ($forbidden) { throw "Refusing to install: local/secret files present in skill/ source: $($forbidden.FullName -join ', ')" }
$sourceLock = Join-Path $source 'scripts\package-lock.json'
if (-not (Test-Path $sourceLock)) { throw 'skill/scripts/package-lock.json missing — commit a lockfile (npm install --package-lock-only).' }

# ---------- 2. Stage + validate EVERYTHING before touching the target ----------
$stage = Join-Path ([System.IO.Path]::GetTempPath()) ("sp-env-stage-" + [guid]::NewGuid().ToString('n'))
try {
    robocopy $source $stage /E /NFL /NDL /NJH /NJS | Out-Null
    Assert-NativeOk 'robocopy (stage)' $RoboOk

    # Validate ALL shipped code in the stage: skill scripts AND project templates.
    foreach ($js in Get-ChildItem (Join-Path $stage 'scripts'), (Join-Path $stage 'templates') -Recurse -Filter *.js) {
        node --check $js.FullName; Assert-NativeOk "node --check $($js.Name)"
    }
    foreach ($ps in Get-ChildItem (Join-Path $stage 'scripts'), (Join-Path $stage 'templates') -Recurse -Filter *.ps1) {
        $errs = $null
        [System.Management.Automation.Language.Parser]::ParseFile($ps.FullName, [ref]$null, [ref]$errs) | Out-Null
        if ($errs) { throw "PowerShell parse errors in $($ps.Name): $($errs -join '; ')" }
    }
    Push-Location (Join-Path $stage 'scripts')
    try {
        node .\test-resolve.js | Select-Object -Last 1
        Assert-NativeOk 'resolver tests (stage)'
    } finally { Pop-Location }

    # Dependencies: prove installability in the STAGE when the lock changed (or the
    # target has no working install); a validated node_modules then ships with the
    # deploy. If the lock is unchanged and the target's deps are intact, skip.
    $lockHash = (Get-FileHash $sourceLock -Algorithm SHA256).Hash
    $targetHashPath = Join-Path $Target 'scripts\node_modules\.package-lock.hash'
    $depsCurrent = (Test-Path (Join-Path $Target 'scripts\node_modules\playwright')) -and
                   (Test-Path $targetHashPath) -and
                   ((Get-Content $targetHashPath -Raw -ErrorAction SilentlyContinue) -eq $lockHash)
    if (-not $depsCurrent) {
        Push-Location (Join-Path $stage 'scripts')
        try {
            npm ci --no-fund --no-audit | Out-Null
            Assert-NativeOk 'npm ci (stage)'
            if (-not (Test-Path 'node_modules\playwright')) { throw 'npm ci reported success but node_modules is incomplete (playwright missing).' }
            Set-Content 'node_modules\.package-lock.hash' $lockHash -NoNewline
        } finally { Pop-Location }
    }

    # ---------- 3. Deploy the validated stage ----------
    New-Item -ItemType Directory -Path $Target -Force | Out-Null
    $manifestPath = Join-Path $Target 'installed-manifest.json'
    $oldManaged = if (Test-Path $manifestPath) { (Get-Content $manifestPath -Raw | ConvertFrom-Json).files } else { @() }

    robocopy $stage $Target /E /NFL /NDL /NJH /NJS | Out-Null
    Assert-NativeOk 'robocopy (deploy)' $RoboOk

    # Prune: only previously managed files, only inside the target, never local state.
    $targetFull = [System.IO.Path]::GetFullPath($Target)
    $newManaged = Get-ChildItem $stage -Recurse -File |
        ForEach-Object { $_.FullName.Substring($stage.Length + 1) } |
        Where-Object { $_ -notmatch '(^|\\)node_modules(\\|$)' }
    $localStatePattern = '(^|\\)(auth|node_modules)(\\|$)|\.local\.json$'
    foreach ($rel in $oldManaged) {
        if ($rel -in $newManaged) { continue }
        if ($rel -match $localStatePattern -or $rel -eq 'installed-manifest.json') { continue }
        if ($rel -match '\.\.' -or [System.IO.Path]::IsPathRooted($rel)) {
            Write-Warning "[install] Ignoring suspicious manifest entry (traversal/rooted): $rel"
            continue
        }
        $staleFull = [System.IO.Path]::GetFullPath((Join-Path $targetFull $rel))
        if (-not $staleFull.StartsWith($targetFull + [System.IO.Path]::DirectorySeparatorChar, [System.StringComparison]::OrdinalIgnoreCase)) {
            Write-Warning "[install] Ignoring manifest entry that resolves outside the target: $rel"
            continue
        }
        if (Test-Path -LiteralPath $staleFull) { Remove-Item -LiteralPath $staleFull -Force; Write-Host "[install] Removed obsolete managed file: $rel" }
    }

    # ---------- 4. Final smoke in the installed location, THEN record success ----------
    Push-Location (Join-Path $Target 'scripts')
    try {
        node .\test-resolve.js | Select-Object -Last 1
        Assert-NativeOk 'resolver tests (installed)'
    } finally { Pop-Location }

    [pscustomobject]@{ installedUtc = (Get-Date).ToUniversalTime().ToString('o'); files = $newManaged } |
        ConvertTo-Json | Set-Content $manifestPath -Encoding utf8
} finally {
    Remove-Item $stage -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host "INSTALL-OK sp-env installed to $Target — all validation (incl. deps) ran in the stage before deploy; manifest written after the installed-location smoke."

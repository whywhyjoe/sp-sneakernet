<#
.SYNOPSIS
Installs the sp-env global skill from this repo's skill/ directory (the versioned
source of truth) into ~/.claude/skills/sp-env. Preserves machine-local state:
*.local.json, auth/ (certs pointer + Playwright profile), node_modules.
Idempotent; run after every git pull that touches skill/.
#>
[CmdletBinding()]
param(
    [string]$Target = (Join-Path $HOME '.claude\skills\sp-env')
)
$ErrorActionPreference = 'Stop'
$source = Join-Path $PSScriptRoot 'skill'
if (-not (Test-Path $source)) { throw "skill/ source not found at $source" }

# Sanity: the source must never contain local state or key material.
$forbidden = Get-ChildItem $source -Recurse -Force -Include '*.local.json', '*.pfx', '*.cer', '*.pem', '*.key' -ErrorAction SilentlyContinue
if ($forbidden) { throw "Refusing to install: local/secret files present in skill/ source: $($forbidden.FullName -join ', ')" }

New-Item -ItemType Directory -Path $Target -Force | Out-Null

# Copy source over target without touching local-only content (never a mirror/delete sync).
robocopy $source $Target /E /NFL /NDL /NJH /NJS /XF *.local.json /XD auth node_modules pw-profile | Out-Null
if ($LASTEXITCODE -ge 8) { throw "robocopy failed with exit code $LASTEXITCODE" }
$script:copied = $LASTEXITCODE  # 0-7 are success codes for robocopy

# Ensure npm deps for the scripts.
$scriptsDir = Join-Path $Target 'scripts'
if (-not (Test-Path (Join-Path $scriptsDir 'node_modules\playwright'))) {
    Push-Location $scriptsDir
    try { npm install --no-fund --no-audit | Out-Null } finally { Pop-Location }
}

# Syntax-check what we installed.
Push-Location $scriptsDir
try {
    Get-ChildItem *.js | ForEach-Object { node --check $_.FullName; if ($LASTEXITCODE -ne 0) { throw "node --check failed: $($_.Name)" } }
    Get-ChildItem *.ps1 | ForEach-Object {
        $errs = $null; [System.Management.Automation.Language.Parser]::ParseFile($_.FullName, [ref]$null, [ref]$errs) | Out-Null
        if ($errs) { throw "PowerShell parse errors in $($_.Name): $($errs -join '; ')" }
    }
    node .\test-resolve.js
    if ($LASTEXITCODE -ne 0) { throw 'resolver tests failed' }
} finally { Pop-Location }

Write-Host "INSTALL-OK sp-env installed to $Target (robocopy code $script:copied); local state preserved; syntax + resolver tests passed."

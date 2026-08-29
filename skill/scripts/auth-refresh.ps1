<#
.SYNOPSIS
Auth health check + repair. (a) PnP app-only cert connect smoke; (b) headless
Playwright profile check with structured failure kinds. Interactive re-login is
launched ONLY for kind=auth_stale (exit 3) — tooling/network/profile-lock
failures are reported as tooling failures, never handed to the human as a login.
Exit 0 = both paths healthy. Runbook: ../runbooks/auth-refresh.md
#>
[CmdletBinding()]
param(
    [switch]$NoRelogin   # report a stale profile instead of launching the headed re-login
)
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\sp-env-common.ps1"

$result = [ordered]@{ pnp = $null; playwright = $null }

# ---------- (a) PnP cert connect smoke ----------
try {
    $conn = Connect-SpEnvDev
    $web  = Get-PnPWeb -Connection $conn
    $result.pnp = @{ ok = $true; title = $web.Title; url = $web.Url }
    Write-Host "[auth-refresh] PNP-OK  Title='$($web.Title)'  Url='$($web.Url)'"
} catch {
    $result.pnp = @{ ok = $false; error = $_.Exception.Message }
    Write-Warning "[auth-refresh] PNP-FAIL $($_.Exception.Message) — not auto-repairable; run setup-dev-auth.ps1 (use -Rotate for a cert/app problem)."
}

# ---------- (b) Playwright profile check ----------
function Invoke-AuthCheck {
    Push-Location $PSScriptRoot
    try { $out = node .\auth-check.js 2>&1; $code = $LASTEXITCODE } finally { Pop-Location }
    $json = ($out | Where-Object { $_ -match '^\{' } | Select-Object -Last 1)
    @{ exit = $code; json = "$json" }
}

$check = Invoke-AuthCheck
Write-Host "[auth-refresh] auth-check (exit $($check.exit)): $($check.json)"

if ($check.exit -eq 0) {
    $result.playwright = @{ ok = $true; detail = $check.json }
} elseif ($check.exit -eq 3 -and -not $NoRelogin) {
    Write-Host "[auth-refresh] Profile auth is stale — launching headed re-login (a browser window will open; a human must complete the Microsoft sign-in)."
    Push-Location $PSScriptRoot
    try { node .\setup-playwright-profile.js; $reExit = $LASTEXITCODE } finally { Pop-Location }
    if ($reExit -eq 0) {
        $check2 = Invoke-AuthCheck
        $result.playwright = @{ ok = ($check2.exit -eq 0); detail = $check2.json }
    } else {
        $result.playwright = @{ ok = $false; error = "re-login failed (exit $reExit)" }
    }
} elseif ($check.exit -eq 3) {
    $result.playwright = @{ ok = $false; detail = $check.json; note = 'auth_stale; relogin suppressed by -NoRelogin' }
} else {
    # Tooling/environment failure — an interactive login would not fix this. Report it.
    $result.playwright = @{ ok = $false; detail = $check.json; note = 'tooling failure — fix the tooling, do not re-login' }
    Write-Warning "[auth-refresh] Playwright check failed for a NON-AUTH reason — see kind in the JSON above."
}

$summary = [pscustomobject]$result | ConvertTo-Json -Depth 4 -Compress
Write-Host "AUTH-REFRESH-RESULT $summary"
if (-not $result.pnp.ok -or -not $result.playwright.ok) { exit 1 }
exit 0

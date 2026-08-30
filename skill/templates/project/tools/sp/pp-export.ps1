<#
.SYNOPSIS
DEV-ONLY: export + unpack a Power Platform solution into the repo's /solution
tree and leave it ready to commit. SOLUTIONS ARE USED FOR FLOWS ONLY here —
they exist solely to get flow versioning; canvas apps ship as .zip/.msapp
(see the sp-env skill's canvas section). Prod has no pac: import is a human
maker-portal step (runbook: pp-import.md in the global skill).

Auth: uses the machine's pac auth profile; creates one interactively (browser
sign-in — a sanctioned human credential moment) if none exists.
Usage: pwsh -File tools/sp/pp-export.ps1 -SolutionName MyFlows [-OutDir solution]
       pwsh -File tools/sp/pp-export.ps1 -List     # just list solutions in the dev env
#>
[CmdletBinding()]
param(
    [string]$SolutionName,
    [string]$OutDir = 'solution',
    [switch]$List
)
$ErrorActionPreference = 'Stop'
$repo = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent

$resolvedJson = node (Join-Path $PSScriptRoot 'resolve.js') $repo
if ($LASTEXITCODE -ne 0) { throw "resolver failed: $resolvedJson" }
$resolved = $resolvedJson | ConvertFrom-Json
if ($resolved.env -ne 'dev') { throw 'pp-export runs on dev only (prod has no pac).' }

# Locate pac (PATH or the dotnet global tools dir).
$pac = (Get-Command pac -ErrorAction SilentlyContinue).Source
if (-not $pac) {
    $cand = Join-Path $HOME '.dotnet\tools\pac.exe'
    if (Test-Path $cand) { $pac = $cand }
    else { throw 'pac CLI not found. Install: dotnet tool install --global Microsoft.PowerApps.CLI.Tool' }
}

# Environment identity from the global skill's machine-local facts.
# pac verbs want a GUID or the Dataverse https URL — NOT the maker portal's
# "Default-<tenantId>" form (that's the GUID with a "Default-" prefix).
$tenants = Get-Content (Join-Path $HOME '.claude\skills\sp-env\tenants.local.json') -Raw | ConvertFrom-Json
$pp = $tenants.dev.powerPlatform
$envId = $pp.environmentId
if (-not $envId -and $pp.environmentUrl) {
    $envId = (($pp.environmentUrl -split '/environments/')[1].Trim('/').Split('/')[0]) -replace '^Default-', ''
}
if (-not $envId) { throw 'tenants.local.json dev.powerPlatform.environmentId (or environmentUrl) missing.' }

# Ensure an authenticated profile (interactive browser sign-in on first run).
$authList = & $pac auth list 2>&1 | Out-String
if ($authList -notmatch '\*') {
    Write-Host "[pp-export] No pac auth profile — creating one (a browser sign-in will appear; complete it as the dev admin)."
    & $pac auth create --environment $envId
    if ($LASTEXITCODE -ne 0) { throw "pac auth create failed (exit $LASTEXITCODE)" }
}

if ($List -or -not $SolutionName) {
    & $pac solution list --environment $envId
    if ($LASTEXITCODE -ne 0) { throw "pac solution list failed (exit $LASTEXITCODE)" }
    if (-not $SolutionName) { Write-Host '[pp-export] Pass -SolutionName <UniqueName> to export one of the above.' }
    return
}

$scratch = Join-Path ([System.IO.Path]::GetTempPath()) ("pp-export-" + [guid]::NewGuid().ToString('n'))
New-Item -ItemType Directory -Path $scratch | Out-Null
try {
    $zip = Join-Path $scratch "$SolutionName.zip"
    Write-Host "[pp-export] Exporting solution '$SolutionName' (unmanaged) from env $envId ..."
    & $pac solution export --name $SolutionName --path $zip --environment $envId --managed false
    if ($LASTEXITCODE -ne 0) { throw "pac solution export failed (exit $LASTEXITCODE)" }

    $dest = Join-Path $repo $OutDir
    & $pac solution unpack --zipfile $zip --folder $dest --packagetype Unmanaged --allowDelete
    if ($LASTEXITCODE -ne 0) { throw "pac solution unpack failed (exit $LASTEXITCODE)" }

    $files = @(Get-ChildItem $dest -Recurse -File)
    $flows = @(Get-ChildItem (Join-Path $dest 'Workflows') -Filter *.json -ErrorAction SilentlyContinue)
    Write-Host "PP-EXPORT-OK solution='$SolutionName' unpacked to $OutDir ($($files.Count) files; $($flows.Count) flow definition(s)). Review and commit."
} finally {
    Remove-Item $scratch -Recurse -Force -ErrorAction SilentlyContinue
}

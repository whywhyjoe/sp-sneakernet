<#
.SYNOPSIS
DEV-ONLY one-time bootstrap (idempotent): ensures the TestRuns list exists and
creates the harness page by copying the site's template page (pages.template)
and rewriting its Script Editor Web Part token __SP_ENV_SCRIPT__ to this
project's harness.js. Uses the global sp-env skill's app-only PnP connection.
Run AFTER the first deploy has synced (harness.js must exist in the library).
Prod has no PnP PowerShell: there, a human creates the harness page once by
copying the template page and pointing its SEWP at harness.js.
#>
[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
$repo = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
. (Join-Path $HOME '.claude\skills\sp-env\scripts\sp-env-common.ps1')

$resolvedJson = node (Join-Path $PSScriptRoot 'resolve.js') $repo
if ($LASTEXITCODE -ne 0) { throw "resolver failed: $resolvedJson" }
$resolved = $resolvedJson | ConvertFrom-Json
if ($resolved.env -ne 'dev') { throw 'bootstrap-dev runs on dev only.' }

$conn = Connect-SpEnvDev
function ServerRel([string]$Url) { ([uri]$Url).AbsolutePath }

# ---- TestRuns list ----
$tr = Get-PnPList -Identity 'TestRuns' -Connection $conn -ErrorAction SilentlyContinue
if (-not $tr) {
    New-PnPList -Title 'TestRuns' -Template GenericList -Connection $conn | Out-Null
    Add-PnPField -List 'TestRuns' -DisplayName 'Suite' -InternalName 'Suite' -Type Text -AddToDefaultView -Connection $conn | Out-Null
    Add-PnPField -List 'TestRuns' -DisplayName 'Passed' -InternalName 'Passed' -Type Boolean -AddToDefaultView -Connection $conn | Out-Null
    Add-PnPField -List 'TestRuns' -DisplayName 'Results' -InternalName 'Results' -Type Note -Connection $conn | Out-Null
    Add-PnPField -List 'TestRuns' -DisplayName 'GitSha' -InternalName 'GitSha' -Type Text -Connection $conn | Out-Null
    Write-Host '[bootstrap-dev] TestRuns list created.'
} else { Write-Host '[bootstrap-dev] TestRuns list exists.' }

# ---- harness page from template page ----
$harnessRel  = ServerRel $resolved.pages.harness.url
$templateRel = ServerRel $resolved.pages.template.url
$harnessJs   = "$($resolved.libraries.scripts.url)/harness.js"

$existing = Get-PnPFile -Url $harnessRel -Connection $conn -ErrorAction SilentlyContinue
if ($existing) {
    Write-Host "[bootstrap-dev] Harness page exists: $harnessRel"
} else {
    $tpl = Get-PnPFile -Url $templateRel -Connection $conn -ErrorAction SilentlyContinue
    if (-not $tpl) {
        throw "Template page missing at $templateRel. ONE-TIME site prep: create a modern page named '$($resolved.pages.template.path)' in SitePages containing your Script Editor Web Part with the literal text __SP_ENV_SCRIPT__ as its script src. Then rerun bootstrap-dev."
    }
    Copy-PnPFile -SourceUrl $templateRel -TargetUrl $harnessRel -Force -Connection $conn
    $leaf = Split-Path $harnessRel -Leaf
    $item = Get-PnPListItem -List 'Site Pages' -Connection $conn -PageSize 500 |
        Where-Object { $_['FileLeafRef'] -eq $leaf } | Select-Object -First 1
    if (-not $item) { throw "Copied harness page but cannot find its list item ($leaf)." }
    $canvas = [string]$item['CanvasContent1']
    if ($canvas -notmatch '__SP_ENV_SCRIPT__') { throw "Template page has no __SP_ENV_SCRIPT__ token in its canvas — fix the template page's SEWP content." }
    Set-PnPListItem -List 'Site Pages' -Identity $item.Id -Values @{ CanvasContent1 = ($canvas -replace '__SP_ENV_SCRIPT__', $harnessJs) } -Connection $conn | Out-Null
    Write-Host "[bootstrap-dev] Harness page created from template, SEWP -> $harnessJs"
}
Write-Host 'BOOTSTRAP-DEV-OK'

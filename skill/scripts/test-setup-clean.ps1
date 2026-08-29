<#
.SYNOPSIS
Regression test (Sol review, finding 1): running setup-dev-auth from an arbitrary
directory must leave that directory unchanged — no PFX/CER/any droppings.
Runs the healthy idempotent path with -SkipPlaywright (fast, no windows).
Exit 0 = PASS.
#>
$ErrorActionPreference = 'Stop'

$probe = Join-Path ([System.IO.Path]::GetTempPath()) ("sp-env-cleantest-" + [guid]::NewGuid().ToString('n'))
New-Item -ItemType Directory -Path $probe | Out-Null
Set-Content (Join-Path $probe 'canary.txt') 'canary'

$before = Get-ChildItem $probe -Recurse -Force | Select-Object -ExpandProperty FullName | Sort-Object
Push-Location $probe
try {
    & (Join-Path $PSScriptRoot 'setup-dev-auth.ps1') -SkipPlaywright | ForEach-Object { "  | $_" }
    $setupExit = $LASTEXITCODE
} finally { Pop-Location }
$after = Get-ChildItem $probe -Recurse -Force | Select-Object -ExpandProperty FullName | Sort-Object

$diff = Compare-Object -ReferenceObject @($before) -DifferenceObject @($after)
Remove-Item $probe -Recurse -Force -ErrorAction SilentlyContinue

if ($diff) {
    Write-Host "CLEAN-DIR-TEST FAIL — setup changed the caller's directory:"
    $diff | ForEach-Object { Write-Host "  $($_.SideIndicator) $($_.InputObject)" }
    exit 1
}
Write-Host "CLEAN-DIR-TEST PASS — caller directory unchanged after setup-dev-auth."
exit 0

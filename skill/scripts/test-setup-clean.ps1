<#
.SYNOPSIS
Regression test (Sol review, finding 1): running setup-dev-auth from an arbitrary
directory must leave that directory unchanged — compared by file SET and CONTENT
HASH, not just names. Runs the healthy idempotent path with -SkipPlaywright.
Known limitation: the registration path itself is not exercised (it would create
a real Entra app); its no-droppings property is enforced structurally instead
(-SkipCertCreation + scratch temp cwd during registration).
Exit 0 = PASS.
#>
$ErrorActionPreference = 'Stop'

$probe = Join-Path ([System.IO.Path]::GetTempPath()) ("sp-env-cleantest-" + [guid]::NewGuid().ToString('n'))
New-Item -ItemType Directory -Path $probe | Out-Null
Set-Content (Join-Path $probe 'canary.txt') 'canary'

function Get-DirSnapshot([string]$Dir) {
    Get-ChildItem $Dir -Recurse -Force -File | Sort-Object FullName | ForEach-Object {
        '{0}|{1}' -f $_.FullName.Substring($Dir.Length + 1), (Get-FileHash $_.FullName -Algorithm SHA256).Hash
    }
}

$before = @(Get-DirSnapshot $probe)
Push-Location $probe
try {
    & (Join-Path $PSScriptRoot 'setup-dev-auth.ps1') -SkipPlaywright | ForEach-Object { "  | $_" }
} finally { Pop-Location }
$after = @(Get-DirSnapshot $probe)

$diff = Compare-Object -ReferenceObject $before -DifferenceObject $after
Remove-Item $probe -Recurse -Force -ErrorAction SilentlyContinue

if ($diff) {
    Write-Host "CLEAN-DIR-TEST FAIL — setup changed the caller's directory (set or content):"
    $diff | ForEach-Object { Write-Host "  $($_.SideIndicator) $($_.InputObject)" }
    exit 1
}
Write-Host "CLEAN-DIR-TEST PASS — caller directory identical (file set + content hashes) after setup-dev-auth."
exit 0

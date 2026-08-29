<#
.SYNOPSIS
Deploy this project's app/ assets to SharePoint. Modes: copy (implemented) |
push | sync-live (phase 3). Reads env.json + env.local.json via the resolver
and REFUSES to run if env.local.json is missing (the resolver enforces this).
copy mode writes into the OneDrive mirror folder; OneDrive sync carries the
files to the library (allow a short sync latency before verifying).
Also generates resolved-env.json (absolute URLs for THIS environment) into the
mirror — a deploy artifact, never committed.
#>
[CmdletBinding()]
param(
    [ValidateSet('copy', 'push', 'sync-live')][string]$Mode
)
$ErrorActionPreference = 'Stop'
$repo = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent

$resolvedJson = node (Join-Path $PSScriptRoot 'resolve.js') $repo
if ($LASTEXITCODE -ne 0) { throw "resolver failed: $resolvedJson" }
$resolved = $resolvedJson | ConvertFrom-Json
if (-not $Mode) { $Mode = $resolved.deploy.mode }

switch ($Mode) {
    'copy' {
        $mirror = $resolved.libraries.scripts.mirror
        if (-not $mirror) { throw "No mirror path resolved for the scripts library (root '$($resolved.libraries.scripts.root)') — check mirrors in tenants.local.json / env.local.json." }
        New-Item -ItemType Directory -Path $mirror -Force | Out-Null

        $sha = (git -C $repo rev-parse --short HEAD 2>$null); if (-not $sha) { $sha = 'uncommitted' }
        $resolved | Add-Member -NotePropertyName gitSha -NotePropertyValue "$sha" -Force
        $resolved | Add-Member -NotePropertyName deployedUtc -NotePropertyValue ((Get-Date).ToUniversalTime().ToString('o')) -Force
        $resolved | ConvertTo-Json -Depth 10 | Set-Content (Join-Path $mirror 'resolved-env.json') -Encoding utf8

        $appDir = Join-Path $repo 'app'
        if (-not (Test-Path $appDir)) { throw "app/ directory not found at $appDir" }
        Copy-Item (Join-Path $appDir '*') $mirror -Recurse -Force
        $count = @(Get-ChildItem $appDir -Recurse -File).Count + 1
        Write-Host "DEPLOY-OK mode=copy files=$count gitSha=$sha mirror='$mirror' (OneDrive sync latency applies before files are live)"
    }
    'push'      { throw 'push mode is a Phase 3 deliverable — not implemented yet.' }
    'sync-live' { throw 'sync-live mode is a Phase 3 deliverable — not implemented yet.' }
}

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
    [ValidateSet('copy', 'push', 'sync-live')][string]$Mode,
    # DEV-ONLY last-mile fallback when OneDrive sync is backed up: after the
    # mirror copy (mirror stays canonical), upload the artifacts directly via
    # PnP and verify SHA256 parity between mirror and live bytes. Never touches
    # sync configuration; OneDrive later syncs identical content.
    [switch]$DirectUpload
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

        # The mirror is an INTENTIONAL reparse point into OneDrive (same local
        # path on every machine) — expected, never something to "fix". Files only
        # reach the library if OneDrive is running; warn loudly if it is not.
        # If sync stays broken beyond that: read-only diagnostics only, then STOP
        # and tell the user. Never create OneDrive folders or change sync config.
        if (-not (Get-Process OneDrive -ErrorAction SilentlyContinue)) {
            Write-Warning 'DEPLOY-SYNC-BLOCKED: OneDrive is NOT running — the copied files will not sync to the library until it is. Ask the user to start OneDrive; do NOT attempt to repair sync configuration.'
        }
        Write-Host "DEPLOY-OK mode=copy files=$count gitSha=$sha mirror='$mirror' (OneDrive sync latency applies before files are live)"

        if ($DirectUpload) {
            if ($resolved.env -ne 'dev') { throw 'DirectUpload is dev-only (prod has no PnP PowerShell).' }
            . (Join-Path $HOME '.claude\skills\sp-env\scripts\sp-env-common.ps1')
            $conn = Connect-SpEnvDev
            $siteRelBase   = ([uri]$resolved.siteUrl).AbsolutePath
            $folderSiteRel = ([uri]$resolved.libraries.scripts.url).AbsolutePath.Substring($siteRelBase.Length).TrimStart('/')
            Resolve-PnPFolder -SiteRelativePath $folderSiteRel -Connection $conn | Out-Null
            $files = Get-ChildItem $mirror -Recurse -File
            $mismatch = @()
            foreach ($f in $files) {
                $rel = ($f.FullName.Substring($mirror.Length + 1)) -replace '\\', '/'
                $sub = if ($rel.Contains('/')) { $rel.Substring(0, $rel.LastIndexOf('/')) } else { '' }
                $targetFolder = if ($sub) { "$folderSiteRel/$sub" } else { $folderSiteRel }
                if ($sub) { Resolve-PnPFolder -SiteRelativePath $targetFolder -Connection $conn | Out-Null }
                Add-PnPFile -Path $f.FullName -Folder $targetFolder -Connection $conn | Out-Null
                $serverRel = ([uri]$resolved.libraries.scripts.url).AbsolutePath + '/' + $rel
                $stream = Get-PnPFile -Url $serverRel -AsMemoryStream -Connection $conn
                if ((Get-FileHash -InputStream $stream -Algorithm SHA256).Hash -ne (Get-FileHash $f.FullName -Algorithm SHA256).Hash) { $mismatch += $rel }
            }
            if ($mismatch) { throw "DIRECT-UPLOAD-PARITY-FAIL: $($mismatch -join ', ')" }
            Write-Host "DIRECT-UPLOAD-OK $(@($files).Count) file(s) live, SHA256 mirror parity MATCH (mirror remains canonical)."
        }
    }
    'push'      { throw 'push mode is a Phase 3 deliverable — not implemented yet.' }
    'sync-live' { throw 'sync-live mode is a Phase 3 deliverable — not implemented yet.' }
}

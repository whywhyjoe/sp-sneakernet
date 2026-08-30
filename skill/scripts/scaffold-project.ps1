<#
.SYNOPSIS
Stamps a new sp-env project repo from the skill's project template.
Copies tools/sp + app templates (with __PROJECT__ token replacement), writes
env.json, .gitignore, the thin .claude/skills/sp-project pointer, a fresh copy
of the resolver, and a dev env.local.json. Refuses to overwrite an existing
env.json. Runbook: ../runbooks/scaffold-project.md
Usage: pwsh -File scaffold-project.ps1 -Path C:\dev\repos\my-app -Project my-app
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$Path,
    [Parameter(Mandatory)][string]$Project
)
$ErrorActionPreference = 'Stop'
if ($Project -notmatch '^[a-z0-9][a-z0-9-]{1,40}$') { throw "Project name must be lowercase alphanumeric/hyphens (got '$Project')." }
$tpl = Join-Path (Split-Path $PSScriptRoot -Parent) 'templates\project'
if (-not (Test-Path $tpl)) { throw "Project template missing at $tpl — reinstall the skill." }
if (Test-Path (Join-Path $Path 'env.json')) { throw "env.json already exists at $Path — refusing to overwrite an existing project." }
if (Test-Path $Path) {
    # Only a fresh/empty directory (a bare `git init` is fine) may be scaffolded —
    # stamping over unrelated files silently overwrites them.
    $existing = @(Get-ChildItem $Path -Force | Where-Object { $_.Name -ne '.git' })
    if ($existing.Count) { throw "Target $Path is not empty ($($existing.Count) item(s) besides .git) — refusing to stamp over existing content." }
}
New-Item -ItemType Directory -Path $Path -Force | Out-Null

# Copy template tree with token replacement in text files.
$textExt = '.json', '.js', '.ps1', '.md', '.html'
Get-ChildItem $tpl -Recurse -File | ForEach-Object {
    $rel = $_.FullName.Substring($tpl.Length + 1)
    $destRel = switch ($rel) {
        'gitignore' { '.gitignore' }
        default { ($rel -replace '^claude-skill\\', '.claude\skills\sp-project\') -replace '^github\\', '.github\' }
    }
    $dest = Join-Path $Path ($destRel -replace '__PROJECT__', $Project)
    New-Item -ItemType Directory -Path (Split-Path $dest -Parent) -Force | Out-Null
    if ($textExt -contains $_.Extension -or $_.Name -eq 'gitignore') {
        (Get-Content $_.FullName -Raw) -replace '__PROJECT__', $Project | Set-Content $dest -Encoding utf8 -NoNewline
    } else {
        Copy-Item $_.FullName $dest -Force
    }
}

# Fresh resolver copy (single source: the installed skill) + committed example.
Copy-Item (Join-Path $PSScriptRoot 'resolve.js') (Join-Path $Path 'tools\sp\resolve.js') -Force
Copy-Item (Join-Path (Split-Path $PSScriptRoot -Parent) 'templates\env.local.example.json') (Join-Path $Path 'env.local.example.json') -Force

# Machine-local env selection (dev machine: tenants.local.json is authoritative).
'{ "env": "dev" }' | Set-Content (Join-Path $Path 'env.local.json') -Encoding utf8

# Prove the stamped repo resolves before declaring success.
$out = node (Join-Path $Path 'tools\sp\resolve.js') $Path
if ($LASTEXITCODE -ne 0) { throw "Scaffold resolution check failed: $out" }

Write-Host "SCAFFOLD-OK project '$Project' at $Path — edit env.json (lists/pages), then: deploy.ps1 -> bootstrap-dev.ps1 (first time) -> run-harness provision/verify/test-smoke."

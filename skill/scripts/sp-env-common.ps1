# Dot-source this from every sp-env script. Loads machine-local facts; refuses to run without them.
$script:SpEnvRoot = Split-Path $PSScriptRoot -Parent

function Get-SpEnvTenants {
    $path = Join-Path $script:SpEnvRoot 'tenants.local.json'
    if (-not (Test-Path $path)) {
        throw "tenants.local.json missing at $path — sp-env scripts refuse to run without it."
    }
    Get-Content $path -Raw | ConvertFrom-Json
}

function Get-SpEnvAuth {
    $path = Join-Path $script:SpEnvRoot 'auth\dev-auth.local.json'
    if (Test-Path $path) { Get-Content $path -Raw | ConvertFrom-Json } else { $null }
}

function Save-SpEnvAuth {
    param(
        [Parameter(Mandatory)][string]$ClientId,
        [Parameter(Mandatory)][string]$Thumbprint,
        [Parameter(Mandatory)][string]$Tenant,
        [string]$ObjectId,
        [string]$AppName,
        [string]$Scope
    )
    $authDir = Join-Path $script:SpEnvRoot 'auth'
    if (-not (Test-Path $authDir)) { New-Item -ItemType Directory -Path $authDir -Force | Out-Null }
    [pscustomobject]@{
        clientId   = $ClientId
        thumbprint = $Thumbprint
        tenant     = $Tenant
        objectId   = $ObjectId
        appName    = $AppName
        scope      = $Scope
    } | ConvertTo-Json | Set-Content (Join-Path $authDir 'dev-auth.local.json') -Encoding utf8
}

function Connect-SpEnvDev {
    # Non-interactive app-only cert connect to the dev site. Returns the connection.
    $t = Get-SpEnvTenants
    $auth = Get-SpEnvAuth
    if (-not $auth) { throw "auth/dev-auth.local.json missing — run setup-dev-auth.ps1 first." }
    Import-Module PnP.PowerShell -ErrorAction Stop
    Connect-PnPOnline -Url $t.dev.siteUrl -ClientId $auth.clientId -Thumbprint $auth.thumbprint -Tenant $auth.tenant -ReturnConnection
}

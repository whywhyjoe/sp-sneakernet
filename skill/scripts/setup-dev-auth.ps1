<#
.SYNOPSIS
Dev auth setup: Entra app (cert, app-only, Sites.Selected scoped to the dev site)
for PnP PowerShell + Playwright persistent browser profile. Idempotent with real
health checks; -Rotate retires the current app+cert and registers a fresh pair.
Runbook: ../runbooks/setup-dev-auth.md

Security design:
- The certificate is created directly in Cert:\CurrentUser\My with a
  NON-EXPORTABLE private key. No PFX/CER file is ever written to disk
  (registration uses -SkipCertCreation; the public key is uploaded via Graph).
- App-only permission is Sites.Selected with a FullControl grant on the dev site
  only — not tenant-wide.
- Registration runs from a scratch temp directory so no tool can drop files into
  the caller's working directory.
#>
[CmdletBinding()]
param(
    [switch]$SkipEntra,      # fail rather than register if no healthy credential exists
    [switch]$SkipPlaywright,
    [switch]$Rotate,         # force new app + cert; delete the old app and cert once the new one verifies
    [switch]$DeviceLogin     # device-code flow for the registration sign-in
)
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\sp-env-common.ps1"

$t = Get-SpEnvTenants
$devSite = $t.dev.siteUrl
$tenant  = $t.dev.tenantDomain

# Errors that plausibly mean "consent/app not propagated yet" — the only ones worth retrying.
$propagationPattern = 'invalid_client|AADSTS700016|AADSTS500011|AADSTS65001|401|403|Unauthorized|token'

function Test-SpEnvAuthHealth {
    $auth = Get-SpEnvAuth
    if (-not $auth -or -not $auth.clientId -or -not $auth.thumbprint -or -not $auth.tenant) {
        return @{ healthy = $false; reason = 'no/incomplete auth pointer' }
    }
    $cert = Get-Item "Cert:\CurrentUser\My\$($auth.thumbprint)" -ErrorAction SilentlyContinue
    if (-not $cert)                { return @{ healthy = $false; reason = "cert $($auth.thumbprint) not in store" } }
    if (-not $cert.HasPrivateKey)  { return @{ healthy = $false; reason = 'cert has no private key' } }
    if ($cert.NotAfter -lt (Get-Date).AddDays(30)) { return @{ healthy = $false; reason = "cert expires $($cert.NotAfter) (<30d)" } }
    try {
        $conn = Connect-SpEnvDev
        $web  = Get-PnPWeb -Connection $conn
        return @{ healthy = $true; reason = 'ok'; webTitle = $web.Title; webUrl = $web.Url }
    } catch {
        return @{ healthy = $false; reason = "remote credential check failed: $($_.Exception.Message.Split("`n")[0])" }
    }
}

# ---------- 1. Entra app + certificate ----------
$health = Test-SpEnvAuthHealth
$oldAuth = Get-SpEnvAuth

if ($health.healthy -and -not $Rotate) {
    Write-Host "[setup-dev-auth] Credential healthy (clientId $($oldAuth.clientId), cert ok, remote connect ok: '$($health.webTitle)') — skipping registration."
} elseif ($SkipEntra) {
    if (-not $health.healthy) { throw "-SkipEntra set but no working PnP credential ($($health.reason)) — refusing to continue." }
} else {
    if (-not $health.healthy) { Write-Host "[setup-dev-auth] Credential unhealthy: $($health.reason) — registering fresh." }
    Import-Module PnP.PowerShell -ErrorAction Stop

    $appName = 'sp-env-dev-agent-' + (Get-Date -Format 'yyyyMMddHHmm')
    Write-Host "[setup-dev-auth] Creating non-exportable certificate in Cert:\CurrentUser\My ..."
    $cert = New-SelfSignedCertificate -Subject "CN=$appName" -CertStoreLocation 'Cert:\CurrentUser\My' `
        -KeyExportPolicy NonExportable -KeyAlgorithm RSA -KeyLength 2048 -KeySpec Signature `
        -HashAlgorithm SHA256 -NotAfter (Get-Date).AddYears(2)

    Write-Host "[setup-dev-auth] Registering Entra app '$appName' on $tenant (Sites.Selected). A sign-in will appear — complete it as the dev-tenant global admin and grant consent."
    $scratch = Join-Path ([System.IO.Path]::GetTempPath()) ("sp-env-setup-" + [guid]::NewGuid().ToString('n'))
    New-Item -ItemType Directory -Path $scratch | Out-Null
    Push-Location $scratch
    try {
        $regParams = @{
            ApplicationName                  = $appName
            Tenant                           = $tenant
            SkipCertCreation                 = $true
            SharePointApplicationPermissions = 'Sites.Selected'
            GraphApplicationPermissions      = 'Sites.Selected'
            SharePointDelegatePermissions    = 'AllSites.FullControl'
            GraphDelegatePermissions         = @('Sites.FullControl.All', 'Application.ReadWrite.All')
        }
        if ($DeviceLogin) { $regParams.DeviceLogin = $true }
        $reg = Register-PnPEntraIDApp @regParams
    } finally {
        Pop-Location
        $leftovers = Get-ChildItem $scratch -Force -ErrorAction SilentlyContinue
        if ($leftovers) { Write-Host "[setup-dev-auth] Removing $($leftovers.Count) scratch file(s) emitted by registration." }
        Remove-Item $scratch -Recurse -Force -ErrorAction SilentlyContinue
    }
    $clientId = $reg.'AzureAppId/ClientId'; if (-not $clientId) { $clientId = $reg.ClientId }
    if (-not $clientId) { throw "Registration returned unexpected shape: $($reg | ConvertTo-Json -Depth 4)" }
    Write-Host "[setup-dev-auth] App registered: clientId=$clientId"

    Write-Host "[setup-dev-auth] Connecting interactively (delegated) to upload the public key and grant site permission — a sign-in may appear."
    $iconn = Connect-PnPOnline -Url $devSite -ClientId $clientId -Interactive -ReturnConnection

    $app = Get-PnPAzureADApp -Identity $clientId -Connection $iconn
    $objectId = $app.Id
    $keyPatch = @{
        keyCredentials = @(@{
            type        = 'AsymmetricX509Cert'
            usage       = 'Verify'
            key         = [Convert]::ToBase64String($cert.GetRawCertData())
            displayName = $appName
        })
    }
    Invoke-PnPGraphMethod -Method Patch -Url "applications/$objectId" -Content $keyPatch -Connection $iconn
    Write-Host "[setup-dev-auth] Public key uploaded to app (objectId $objectId). Private key never left the certificate store."

    try {
        $grant = Grant-PnPAzureADAppSitePermission -AppId $clientId -DisplayName $appName -Permissions FullControl -Site $devSite -Connection $iconn
    } catch {
        Write-Host "[setup-dev-auth] Direct FullControl grant failed ($($_.Exception.Message.Split("`n")[0])) — granting Write then elevating."
        $grant = Grant-PnPAzureADAppSitePermission -AppId $clientId -DisplayName $appName -Permissions Write -Site $devSite -Connection $iconn
        $grantId = $grant.Id
        Set-PnPAzureADAppSitePermission -PermissionId $grantId -Permissions FullControl -Site $devSite -Connection $iconn | Out-Null
    }
    Write-Host "[setup-dev-auth] Sites.Selected FullControl granted on the dev site."

    Save-SpEnvAuth -ClientId $clientId -Thumbprint $cert.Thumbprint -Tenant $tenant -ObjectId $objectId -AppName $appName -Scope 'Sites.Selected'

    # Smoke test with propagation retry — ONLY valid right after a fresh registration.
    Write-Host "[setup-dev-auth] Smoke test: app-only cert connect to the dev site ..."
    $deadline = (Get-Date).AddMinutes(5); $web = $null
    while (-not $web) {
        try {
            $conn = Connect-SpEnvDev
            $web  = Get-PnPWeb -Connection $conn
        } catch {
            $msg = $_.Exception.Message.Split("`n")[0]
            if ($msg -notmatch $propagationPattern) { throw "App-only connect failed with a non-propagation error: $msg" }
            if ((Get-Date) -gt $deadline) { throw "App-only connect still failing after 5 min: $msg" }
            Write-Host "[setup-dev-auth] Propagation not complete ($msg) — retrying in 20s..."
            Start-Sleep -Seconds 20
        }
    }
    Write-Host "[setup-dev-auth] PNP-OK  Title='$($web.Title)'  Url='$($web.Url)'"

    # Retire the previous app + cert only after the new credential is proven.
    if ($oldAuth -and $oldAuth.clientId -and $oldAuth.clientId -ne $clientId) {
        Write-Host "[setup-dev-auth] Retiring previous app $($oldAuth.clientId) and cert $($oldAuth.thumbprint)."
        try { Remove-PnPAzureADApp -Identity $oldAuth.clientId -Connection $iconn -Force } catch { Write-Warning "Old app removal failed (remove manually in Entra): $($_.Exception.Message.Split("`n")[0])" }
        if ($oldAuth.thumbprint) { Remove-Item "Cert:\CurrentUser\My\$($oldAuth.thumbprint)" -ErrorAction SilentlyContinue }
    }
}

# Healthy-path smoke output (no retry loop — nothing to propagate).
if ($health.healthy -and -not $Rotate) {
    Write-Host "[setup-dev-auth] PNP-OK  Title='$($health.webTitle)'  Url='$($health.webUrl)'"
}

# ---------- 2. Playwright persistent profile ----------
if (-not $SkipPlaywright) {
    Write-Host "[setup-dev-auth] Checking Playwright profile (headed login only if needed)..."
    Push-Location $PSScriptRoot
    try { node .\setup-playwright-profile.js; $pwExit = $LASTEXITCODE } finally { Pop-Location }
    if ($pwExit -ne 0) { throw "setup-playwright-profile.js failed (exit $pwExit)." }
}

Write-Host "[setup-dev-auth] DONE."

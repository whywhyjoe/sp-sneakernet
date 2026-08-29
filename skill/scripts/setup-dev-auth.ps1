<#
.SYNOPSIS
Dev auth setup/audit. Two Entra apps:
  - WORKLOAD app (sp-env-dev-agent-*): ONLY application permissions
    (SharePoint Sites.Selected + Graph Sites.Selected), certificate credential,
    FullControl granted on the dev site only. Never used interactively.
  - BOOTSTRAP app (sp-env-admin-bootstrap): ONLY delegated permissions, no
    credentials. Used for interactive admin sessions (key upload, grants,
    retirement, audit); useless without an interactive admin sign-in.
Idempotent with invariant-enforcing health checks; -Rotate re-keys; -Audit runs
a deep verification (and repairs legacy delegated scopes on the workload app).
Interrupted registrations resume via auth\pending-app.local.json; retirements
are tracked in auth\retire-app.local.json and MUST complete before anything else.
Runbook: ../runbooks/setup-dev-auth.md

Security invariants enforced (health + audit):
  - pointer complete (clientId, objectId, thumbprint, tenant, appName) and scope=Sites.Selected
  - cert in CurrentUser store, private key present, ExportPolicy=None, >30d validity
  - app object exists and matches pointer; our cert thumbprint among its keyCredentials
  - requiredResourceAccess: application permissions from the Sites.Selected allowlist
    ONLY; no delegated scopes (legacy ones are stripped and their consent revoked)
  - exactly one site grant for the app on the dev site, role fullcontrol
  - no cert/key file ever written to disk (SkipCertCreation + Graph key upload)
#>
[CmdletBinding()]
param(
    [switch]$SkipEntra,      # fail rather than register if no healthy credential exists
    [switch]$SkipPlaywright,
    [switch]$Rotate,         # force new workload app + cert; old pair retired after new one verifies
    [switch]$Audit,          # deep audit via bootstrap interactive session (repairs legacy delegated scopes)
    [switch]$DeviceLogin     # device-code flow for registration sign-ins
)
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\sp-env-common.ps1"

$t = Get-SpEnvTenants
$devSite = $t.dev.siteUrl
$tenant  = $t.dev.tenantDomain
$authDir       = Join-Path (Split-Path $PSScriptRoot -Parent) 'auth'
$pendingPath   = Join-Path $authDir 'pending-app.local.json'
$retirePath    = Join-Path $authDir 'retire-app.local.json'
$bootstrapPath = Join-Path $authDir 'bootstrap-app.local.json'

# Known-good application permission ids (allowlist for the workload app).
$SpoResourceAppId   = '00000003-0000-0ff1-ce00-000000000000' # SharePoint Online
$GraphResourceAppId = '00000003-0000-0000-c000-000000000000' # Microsoft Graph
$AllowedAppRoles = @(
    '20d37865-089c-4dee-8c41-6967602d4ac8', # SharePoint Sites.Selected (application) — verified live on tenant
    '883ea226-0bf2-4a8f-9f9d-92c9162a727d'  # Graph Sites.Selected (application) — verified live on tenant
)

# Errors that plausibly mean "consent/app/key not propagated yet" — the only ones worth retrying.
$propagationPattern = 'invalid_client|AADSTS700016|AADSTS500011|AADSTS65001|AADSTS700027|key was not found|401|403|Unauthorized|token'

function Read-JsonFile([string]$Path) { if (Test-Path $Path) { Get-Content $Path -Raw | ConvertFrom-Json } else { $null } }
function Write-JsonFile([string]$Path, $Obj) { $Obj | ConvertTo-Json | Set-Content $Path -Encoding utf8 }

function Get-CertExportPolicy($cert) {
    try {
        $rsa = [System.Security.Cryptography.X509Certificates.RSACertificateExtensions]::GetRSAPrivateKey($cert)
        return "$($rsa.Key.ExportPolicy)"
    } catch { return $null }
}

function Test-SpEnvAuthHealth {
    $auth = Get-SpEnvAuth
    foreach ($f in 'clientId', 'thumbprint', 'tenant', 'objectId', 'appName') {
        if (-not $auth -or -not $auth.$f) { return @{ healthy = $false; reason = "auth pointer missing field '$f'" } }
    }
    if ($auth.scope -ne 'Sites.Selected') { return @{ healthy = $false; reason = "pointer scope '$($auth.scope)' is not Sites.Selected" } }
    $cert = Get-Item "Cert:\CurrentUser\My\$($auth.thumbprint)" -ErrorAction SilentlyContinue
    if (-not $cert)                { return @{ healthy = $false; reason = "cert $($auth.thumbprint) not in store" } }
    if (-not $cert.HasPrivateKey)  { return @{ healthy = $false; reason = 'cert has no private key' } }
    if ($cert.NotAfter -lt (Get-Date).AddDays(30)) { return @{ healthy = $false; reason = "cert expires $($cert.NotAfter) (<30d)" } }
    $policy = Get-CertExportPolicy $cert
    if ($policy -ne 'None') { return @{ healthy = $false; reason = "cert key export policy is '$policy' (must be None)" } }
    try {
        $conn = Connect-SpEnvDev
        $web  = Get-PnPWeb -Connection $conn
        return @{ healthy = $true; reason = 'ok'; webTitle = $web.Title; webUrl = $web.Url }
    } catch {
        return @{ healthy = $false; reason = "remote credential check failed: $($_.Exception.Message.Split("`n")[0])" }
    }
}

function Register-BootstrapApp {
    $bs = Read-JsonFile $bootstrapPath
    if ($bs -and $bs.clientId) { return $bs }
    Write-Host "[setup-dev-auth] Registering BOOTSTRAP admin app 'sp-env-admin-bootstrap' (delegated-only, no credentials). A sign-in/consent will appear."
    $p = @{
        ApplicationName               = 'sp-env-admin-bootstrap'
        Tenant                        = $tenant
        SkipCertCreation              = $true
        SharePointDelegatePermissions = 'AllSites.FullControl'
        GraphDelegatePermissions      = @('Application.ReadWrite.All', 'Sites.FullControl.All', 'DelegatedPermissionGrant.ReadWrite.All')
    }
    if ($DeviceLogin) { $p.DeviceLogin = $true }
    $reg = Register-PnPEntraIDApp @p
    $cid = $reg.'AzureAppId/ClientId'; if (-not $cid) { $cid = $reg.ClientId }
    if (-not $cid) { throw "Bootstrap registration returned unexpected shape: $($reg | ConvertTo-Json -Depth 4)" }
    $bs = [pscustomobject]@{ clientId = $cid; appName = 'sp-env-admin-bootstrap' }
    Write-JsonFile $bootstrapPath $bs
    $bs
}

$script:BootstrapConn = $null
function Get-BootstrapConn {
    if ($script:BootstrapConn) { return $script:BootstrapConn }
    $bs = Register-BootstrapApp
    # HARD CAP on interactive attempts: a sign-in-spawning loop must never be
    # unbounded. Attempt 1 = normal; if it fails on a consent-shaped error we
    # open the admin-consent URL, wait, and make exactly ONE more attempt.
    $maxAttempts = 2
    for ($attempt = 1; $attempt -le $maxAttempts; $attempt++) {
        try {
            Write-Host "[setup-dev-auth] Opening admin session (bootstrap app), attempt $attempt of $maxAttempts — complete the sign-in."
            if ($DeviceLogin) {
                $conn = Connect-PnPOnline -Url $devSite -ClientId $bs.clientId -DeviceLogin -ReturnConnection
            } else {
                $conn = Connect-PnPOnline -Url $devSite -ClientId $bs.clientId -Interactive -ReturnConnection
            }
            # Probe the permission this session actually needs next (Application.ReadWrite.All)
            # — NOT /me, which needs User.Read, a scope this app deliberately lacks.
            Invoke-PnPGraphMethod -Url 'applications?$top=1&$select=id' -Connection $conn | Out-Null
            $script:BootstrapConn = $conn
            return $conn
        } catch {
            $msg = $_.Exception.Message.Split("`n")[0]
            if ($msg -notmatch 'Forbidden|403|Insufficient|Authorization_RequestDenied|AADSTS65001|consent') { throw }
            $u = "https://login.microsoftonline.com/$tenant/adminconsent?client_id=$($bs.clientId)"
            if ($attempt -lt $maxAttempts) {
                Write-Host "[setup-dev-auth] Graph probe denied ($msg). Opening admin-consent page — approve it, then the ONE retry follows in 45s: $u"
                Start-Process $u
                Start-Sleep -Seconds 45
            } else {
                throw "Bootstrap Graph access still denied after $maxAttempts sign-ins ($msg). If you just consented, wait a minute and rerun. Consent URL: $u"
            }
        }
    }
}

function Test-AppAbsent {
    # Deterministic absence check: a filter query returns an EMPTY LIST for a
    # deleted app and THROWS on transport/permission failures — a transient
    # error can never be mistaken for "the app is gone".
    param([string]$AppClientId, $Conn)
    $res = Invoke-PnPGraphMethod -Url "applications?`$filter=appId eq '$AppClientId'&`$select=id" -Connection $Conn
    return (@($res.value).Count -eq 0)
}

function Complete-Retirement {
    # Deletes the retired app, VERIFIES it is gone (deterministically), then and
    # only then removes its certificate and the retirement marker. Any failure —
    # including a failure to VERIFY — throws, so the marker survives for the
    # next attempt.
    $r = Read-JsonFile $retirePath
    if (-not $r) { return }
    Write-Host "[setup-dev-auth] Completing retirement of previous app $($r.clientId)."
    $conn = Get-BootstrapConn
    if (-not (Test-AppAbsent -AppClientId $r.clientId -Conn $conn)) {
        Remove-PnPAzureADApp -Identity $r.clientId -Connection $conn -Force
        $deadline = (Get-Date).AddMinutes(2)
        while (-not (Test-AppAbsent -AppClientId $r.clientId -Conn $conn)) {
            if ((Get-Date) -gt $deadline) { throw "Old app $($r.clientId) still present after deletion — retirement NOT complete; marker kept." }
            Start-Sleep -Seconds 10
        }
    }
    if ($r.thumbprint) { Remove-Item "Cert:\CurrentUser\My\$($r.thumbprint)" -ErrorAction SilentlyContinue }
    Remove-Item $retirePath -Force
    Write-Host "[setup-dev-auth] RETIRE-OK old app verified absent; old cert and marker removed."
}

function Invoke-DeepAudit {
    param([switch]$RepairDelegated)
    $auth = Get-SpEnvAuth
    $cert = Get-Item "Cert:\CurrentUser\My\$($auth.thumbprint)"
    $conn = Get-BootstrapConn
    $fail = New-Object System.Collections.Generic.List[string]

    $app = $null
    try { $app = Invoke-PnPGraphMethod -Url "applications/$($auth.objectId)?`$select=id,appId,displayName,keyCredentials,requiredResourceAccess" -Connection $conn } catch { $fail.Add("app object $($auth.objectId) not readable: $($_.Exception.Message.Split("`n")[0])") }
    if ($app) {
        if ($app.appId -ne $auth.clientId) { $fail.Add("app object appId $($app.appId) != pointer clientId $($auth.clientId)") }
        # Match our key: preferred by recorded keyId; else by customKeyIdentifier in
        # either encoding (AAD may omit it on PATCHed keys); else by the displayName
        # we set at upload. Functional proof (app-only connect) runs separately.
        $certHashB64 = [Convert]::ToBase64String($cert.GetCertHash())
        $keyMatch = @($app.keyCredentials | Where-Object {
            ($auth.keyId -and $_.keyId -eq $auth.keyId) -or
            $_.customKeyIdentifier -eq $certHashB64 -or
            $_.customKeyIdentifier -eq $cert.Thumbprint -or
            $_.displayName -eq $auth.appName
        })
        if (-not $keyMatch.Count) {
            $fail.Add("local certificate not among app keyCredentials (count=$(@($app.keyCredentials).Count))")
        } elseif (-not $auth.keyId -and $keyMatch[0].keyId) {
            # Backfill the exact keyId into the pointer for future audits.
            Save-SpEnvAuth -ClientId $auth.clientId -Thumbprint $auth.thumbprint -Tenant $auth.tenant `
                -ObjectId $auth.objectId -AppName $auth.appName -Scope $auth.scope -KeyId $keyMatch[0].keyId
            Write-Host "[setup-dev-auth] Pointer backfilled with keyId $($keyMatch[0].keyId)."
        }

        $delegated = @($app.requiredResourceAccess | ForEach-Object { $_.resourceAccess } | Where-Object { $_.type -eq 'Scope' })
        if ($delegated.Count -and $RepairDelegated) {
            Write-Host "[setup-dev-auth] Repairing: stripping $($delegated.Count) delegated scope(s) from workload app and revoking their consent."
            $rra = @()
            foreach ($res in $app.requiredResourceAccess) {
                $roles = @($res.resourceAccess | Where-Object { $_.type -eq 'Role' })
                if ($roles.Count) { $rra += @{ resourceAppId = $res.resourceAppId; resourceAccess = @($roles | ForEach-Object { @{ id = $_.id; type = 'Role' } }) } }
            }
            Invoke-PnPGraphMethod -Method Patch -Url "applications/$($auth.objectId)" -Content @{ requiredResourceAccess = $rra } -Connection $conn
            $sp = (Invoke-PnPGraphMethod -Url "servicePrincipals?`$filter=appId eq '$($auth.clientId)'" -Connection $conn).value | Select-Object -First 1
            if ($sp) {
                $grants = (Invoke-PnPGraphMethod -Url "oauth2PermissionGrants?`$filter=clientId eq '$($sp.id)'" -Connection $conn).value
                foreach ($g in $grants) { Invoke-PnPGraphMethod -Method Delete -Url "oauth2PermissionGrants/$($g.id)" -Connection $conn }
                Write-Host "[setup-dev-auth] Revoked $(@($grants).Count) delegated consent grant(s)."
            }
            $app = Invoke-PnPGraphMethod -Url "applications/$($auth.objectId)?`$select=requiredResourceAccess" -Connection $conn
            $delegated = @($app.requiredResourceAccess | ForEach-Object { $_.resourceAccess } | Where-Object { $_.type -eq 'Scope' })
        }
        if ($delegated.Count) { $fail.Add("workload app still declares $($delegated.Count) delegated scope(s)") }
        $roleIds = @($app.requiredResourceAccess | ForEach-Object { $_.resourceAccess } | Where-Object { $_.type -eq 'Role' } | ForEach-Object { $_.id })
        foreach ($id in $roleIds) { if ($id -notin $AllowedAppRoles) { $fail.Add("unexpected application permission $id (allowlist: Sites.Selected only)") } }
        if (-not $roleIds.Count) { $fail.Add('workload app has no application permissions at all') }
    }

    $grants = @()
    try { $grants = @(Get-PnPAzureADAppSitePermission -Site $devSite -Connection $conn | Where-Object { "$($_.Apps)" -match $auth.clientId }) } catch { $fail.Add("cannot read site grants: $($_.Exception.Message.Split("`n")[0])") }
    if ($grants.Count -ne 1) { $fail.Add("expected exactly 1 site grant for app, found $($grants.Count)") }
    elseif (@($grants[0].Roles) -notcontains 'FullControl' -and "$($grants[0].Roles)" -notmatch 'fullcontrol') { $fail.Add("site grant role is '$($grants[0].Roles)', not FullControl") }

    if ($fail.Count) { throw "AUDIT-FAIL: $($fail -join ' | ')" }
    Write-Host "AUDIT-OK app=$($auth.clientId) key-registered=yes delegated-scopes=0 app-roles=Sites.Selected-only site-grant=FullControl"
}

# ==================== main flow ====================

$health  = Test-SpEnvAuthHealth
$oldAuth = Get-SpEnvAuth
$pending = Read-JsonFile $pendingPath

# 0. An unfinished retirement is completed ONLY once the replacement credential
#    is proven: either the pending registration resumes first (its own path ends
#    with smoke test + Complete-Retirement), or — with no pending work — the
#    active credential must pass the full health check before the old app is
#    destroyed. A crash mid-rotation therefore never deletes the last working
#    credential.
if ((Test-Path $retirePath) -and -not $pending) {
    if (-not $health.healthy) {
        throw "Retirement pending but the active credential is UNHEALTHY ($($health.reason)) — refusing to delete the previous app. Fix/rotate the active credential first; the retirement marker is kept."
    }
    Import-Module PnP.PowerShell -ErrorAction Stop
    Complete-Retirement
}

if ($health.healthy -and -not $Rotate -and -not $pending) {
    Write-Host "[setup-dev-auth] Credential healthy (clientId $($oldAuth.clientId), scope Sites.Selected, key non-exportable, remote connect ok) — skipping registration."
    Write-Host "[setup-dev-auth] PNP-OK  Title='$($health.webTitle)'  Url='$($health.webUrl)'"
    if ($Audit) { Import-Module PnP.PowerShell -ErrorAction Stop; Invoke-DeepAudit -RepairDelegated }
} elseif ($SkipEntra) {
    if (-not $health.healthy) { throw "-SkipEntra set but no healthy PnP credential ($($health.reason)) — refusing to continue." }
    Write-Host "[setup-dev-auth] PNP-OK  Title='$($health.webTitle)'  Url='$($health.webUrl)'  (-SkipEntra; pending/rotate deferred)"
} else {
    Import-Module PnP.PowerShell -ErrorAction Stop

    if ($pending) {
        $appName  = $pending.appName
        $clientId = $pending.clientId
        $cert     = Get-Item "Cert:\CurrentUser\My\$($pending.thumbprint)" -ErrorAction Stop
        Write-Host "[setup-dev-auth] Resuming pending registration: app '$appName' (clientId $clientId)."
    } else {
        if (-not $health.healthy) { Write-Host "[setup-dev-auth] Credential unhealthy: $($health.reason) — registering fresh." }
        $appName = 'sp-env-dev-agent-' + (Get-Date -Format 'yyyyMMddHHmm')
        Write-Host "[setup-dev-auth] Creating non-exportable certificate in Cert:\CurrentUser\My ..."
        $cert = New-SelfSignedCertificate -Subject "CN=$appName" -CertStoreLocation 'Cert:\CurrentUser\My' `
            -KeyExportPolicy NonExportable -KeyAlgorithm RSA -KeyLength 2048 -KeySpec Signature `
            -HashAlgorithm SHA256 -NotAfter (Get-Date).AddYears(2)

        Write-Host "[setup-dev-auth] Registering WORKLOAD app '$appName' on $tenant (application perms: Sites.Selected only). A sign-in/consent will appear."
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
            }
            if ($DeviceLogin) { $regParams.DeviceLogin = $true }
            $reg = Register-PnPEntraIDApp @regParams
        } finally {
            Pop-Location
            Remove-Item $scratch -Recurse -Force -ErrorAction SilentlyContinue
        }
        $clientId = $reg.'AzureAppId/ClientId'; if (-not $clientId) { $clientId = $reg.ClientId }
        if (-not $clientId) { throw "Registration returned unexpected shape: $($reg | ConvertTo-Json -Depth 4)" }
        Write-Host "[setup-dev-auth] Workload app registered: clientId=$clientId"
        Write-JsonFile $pendingPath ([pscustomobject]@{ appName = $appName; clientId = $clientId; thumbprint = $cert.Thumbprint })
    }

    # Post-registration via bootstrap admin session: key upload + site grant (role-verified).
    $conn = Get-BootstrapConn
    $deadline = (Get-Date).AddMinutes(8); $done = $false
    while (-not $done) {
        try {
            $app = Get-PnPAzureADApp -Identity $clientId -Connection $conn
            $objectId = $app.Id
            Invoke-PnPGraphMethod -Method Patch -Url "applications/$objectId" -Content @{
                keyCredentials = @(@{ type = 'AsymmetricX509Cert'; usage = 'Verify'; key = [Convert]::ToBase64String($cert.GetRawCertData()); displayName = $appName })
            } -Connection $conn
            Write-Host "[setup-dev-auth] Public key uploaded (objectId $objectId). Private key never left the certificate store."

            $existing = @()
            try { $existing = @(Get-PnPAzureADAppSitePermission -Site $devSite -Connection $conn | Where-Object { "$($_.Apps)" -match $clientId }) } catch { }
            if ($existing.Count -and ("$($existing[0].Roles)" -match 'fullcontrol' -or @($existing[0].Roles) -contains 'FullControl')) {
                Write-Host "[setup-dev-auth] Existing FullControl site grant found — keeping it."
            } elseif ($existing.Count) {
                Write-Host "[setup-dev-auth] Existing grant has role '$($existing[0].Roles)' — elevating to FullControl."
                Set-PnPAzureADAppSitePermission -PermissionId $existing[0].Id -Permissions FullControl -Site $devSite -Connection $conn | Out-Null
            } else {
                try {
                    Grant-PnPAzureADAppSitePermission -AppId $clientId -DisplayName $appName -Permissions FullControl -Site $devSite -Connection $conn | Out-Null
                } catch {
                    Write-Host "[setup-dev-auth] Direct FullControl grant failed ($($_.Exception.Message.Split("`n")[0])) — granting Write then elevating."
                    $g = Grant-PnPAzureADAppSitePermission -AppId $clientId -DisplayName $appName -Permissions Write -Site $devSite -Connection $conn
                    Set-PnPAzureADAppSitePermission -PermissionId $g.Id -Permissions FullControl -Site $devSite -Connection $conn | Out-Null
                }
            }
            # Verify the final role explicitly — never assume the elevation stuck.
            $final = @(Get-PnPAzureADAppSitePermission -Site $devSite -Connection $conn | Where-Object { "$($_.Apps)" -match $clientId })
            if ($final.Count -ne 1 -or ("$($final[0].Roles)" -notmatch 'fullcontrol' -and @($final[0].Roles) -notcontains 'FullControl')) {
                throw "Site grant verification failed: count=$($final.Count) roles='$($final | ForEach-Object Roles)'"
            }
            Write-Host "[setup-dev-auth] Sites.Selected FullControl grant verified on the dev site."
            $done = $true
        } catch {
            $msg = $_.Exception.Message.Split("`n")[0]
            if ($msg -notmatch 'Forbidden|403|Insufficient|Authorization_RequestDenied') { throw }
            if ((Get-Date) -gt $deadline) { throw "Post-registration still failing after wait: $msg" }
            Write-Host "[setup-dev-auth] Waiting for permission propagation ($msg) — retrying in 25s..."
            Start-Sleep -Seconds 25
        }
    }

    # Record the retirement obligation BEFORE the pointer switch (crash-safe).
    if ($oldAuth -and $oldAuth.clientId -and $oldAuth.clientId -ne $clientId) {
        Write-JsonFile $retirePath ([pscustomobject]@{ clientId = $oldAuth.clientId; thumbprint = $oldAuth.thumbprint; objectId = $oldAuth.objectId })
    }
    Save-SpEnvAuth -ClientId $clientId -Thumbprint $cert.Thumbprint -Tenant $tenant -ObjectId $objectId -AppName $appName -Scope 'Sites.Selected'

    # Smoke test with propagation retry — ONLY valid right after a fresh registration.
    Write-Host "[setup-dev-auth] Smoke test: app-only cert connect to the dev site ..."
    $deadline = (Get-Date).AddMinutes(6); $web = $null
    while (-not $web) {
        try {
            $c = Connect-SpEnvDev
            $web = Get-PnPWeb -Connection $c
        } catch {
            $msg = $_.Exception.Message.Split("`n")[0]
            if ($msg -notmatch $propagationPattern) { throw "App-only connect failed with a non-propagation error: $msg" }
            if ((Get-Date) -gt $deadline) { throw "App-only connect still failing after 6 min: $msg" }
            Write-Host "[setup-dev-auth] Propagation not complete ($msg) — retrying in 20s..."
            Start-Sleep -Seconds 20
        }
    }
    Write-Host "[setup-dev-auth] PNP-OK  Title='$($web.Title)'  Url='$($web.Url)'"
    Remove-Item $pendingPath -ErrorAction SilentlyContinue

    Complete-Retirement          # throws (and keeps the marker) if the old app can't be confirmed gone
    Invoke-DeepAudit -RepairDelegated
}

# ---------- Playwright persistent profile ----------
if (-not $SkipPlaywright) {
    Write-Host "[setup-dev-auth] Checking Playwright profile (headed login only if needed)..."
    Push-Location $PSScriptRoot
    try { node .\setup-playwright-profile.js; $pwExit = $LASTEXITCODE } finally { Pop-Location }
    if ($pwExit -ne 0) { throw "setup-playwright-profile.js failed (exit $pwExit)." }
}

Write-Host "[setup-dev-auth] DONE."

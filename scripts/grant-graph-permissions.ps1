#Requires -Modules Microsoft.Graph.Applications, Microsoft.Graph.Sites
<#
.SYNOPSIS
    Grants the Logic App's user-assigned managed identity least-privilege
    Microsoft Graph access to a single SharePoint site, for the opt-in
    enableSharePointArchive feature. Uses "Sites.Selected" (least privilege --
    scoped to one site) rather than the tenant-wide Sites.ReadWrite.All.

.DESCRIPTION
    This is a manual/scripted prerequisite because Graph application-permission
    consent and per-site grants are Microsoft Graph API operations, not
    ARM/Bicep resources -- there is no verified AVM module or raw ARM resource
    type for them. Run once, after the Logic App's user-assigned identity
    exists, before enabling enableSharePointArchive in infra/params/*.bicepparam.
    Requires a caller with Global Administrator or Privileged Role
    Administrator (to consent the app role) and Sites.FullControl.All delegated
    permission (to grant the per-site permission) -- these are one-time,
    interactive, admin-consented actions by design.

.PARAMETER LogicAppIdentityObjectId
    Object (principal) ID of the Logic App's user-assigned managed identity
    (infra output: identityLogic.outputs.principalId in main.bicep, or
    `az identity show --ids <resourceId> --query principalId`).

.PARAMETER SharePointSiteId
    Microsoft Graph site ID, e.g. contoso.sharepoint.com,<siteGuid>,<webGuid>
    (matches the sharePointArchive.siteId Bicep parameter).

.PARAMETER Role
    Site-level permission role to grant: 'write' (read+write, needed to
    archive documents) or 'read'.

.EXAMPLE
    ./grant-graph-permissions.ps1 -LogicAppIdentityObjectId <principal-guid> -SharePointSiteId "contoso.sharepoint.com,11111111-1111-1111-1111-111111111111,22222222-2222-2222-2222-222222222222"
#>
[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [Parameter(Mandatory = $true)]
    [string]$LogicAppIdentityObjectId,

    [Parameter(Mandatory = $true)]
    [string]$SharePointSiteId,

    [ValidateSet('read', 'write')]
    [string]$Role = 'write'
)

$ErrorActionPreference = 'Stop'
$graphAppId = '00000003-0000-0000-c000-000000000000' # well-known Microsoft Graph application ID, stable across all tenants

Write-Host 'Connecting to Microsoft Graph (interactive, admin consent required) ...' -ForegroundColor Cyan
Connect-MgGraph -Scopes 'Application.Read.All', 'AppRoleAssignment.ReadWrite.All', 'Sites.FullControl.All' | Out-Null

Write-Host 'Resolving the Microsoft Graph service principal ...' -ForegroundColor Cyan
$graphServicePrincipal = Get-MgServicePrincipal -Filter "appId eq '$graphAppId'"

Write-Host "Resolving the 'Sites.Selected' application app role ..." -ForegroundColor Cyan
$sitesSelectedRole = $graphServicePrincipal.AppRoles | Where-Object { $_.Value -eq 'Sites.Selected' }
if (-not $sitesSelectedRole) {
    throw "Could not find the Sites.Selected app role on the Microsoft Graph service principal. Verify Microsoft Graph still exposes this role."
}

Write-Host "Assigning app role 'Sites.Selected' to the Logic App identity ($LogicAppIdentityObjectId) ..." -ForegroundColor Cyan
$existingAssignment = Get-MgServicePrincipalAppRoleAssignment -ServicePrincipalId $LogicAppIdentityObjectId -ErrorAction SilentlyContinue |
    Where-Object { $_.AppRoleId -eq $sitesSelectedRole.Id -and $_.ResourceId -eq $graphServicePrincipal.Id }

if (-not $existingAssignment) {
    if ($PSCmdlet.ShouldProcess($LogicAppIdentityObjectId, 'Grant Sites.Selected app role')) {
        New-MgServicePrincipalAppRoleAssignment -ServicePrincipalId $LogicAppIdentityObjectId `
            -PrincipalId $LogicAppIdentityObjectId `
            -ResourceId $graphServicePrincipal.Id `
            -AppRoleId $sitesSelectedRole.Id | Out-Null
        Write-Host 'Granted the Sites.Selected app role.' -ForegroundColor Green
    }
}
else {
    Write-Host 'Sites.Selected app role already granted -- leaving as-is.' -ForegroundColor Yellow
}

Write-Host "Granting per-site '$Role' permission on site $SharePointSiteId (this is the second, required step -- Sites.Selected alone grants no site access until scoped here) ..." -ForegroundColor Cyan
$permissionBody = @{
    roles              = @($Role)
    grantedToIdentities = @(
        @{
            application = @{
                id          = (Get-MgServicePrincipal -ServicePrincipalId $LogicAppIdentityObjectId).AppId
                displayName = (Get-MgServicePrincipal -ServicePrincipalId $LogicAppIdentityObjectId).DisplayName
            }
        }
    )
}

if ($PSCmdlet.ShouldProcess($SharePointSiteId, "Grant site-level $Role permission")) {
    New-MgSitePermission -SiteId $SharePointSiteId -BodyParameter $permissionBody | Out-Null
    Write-Host "Granted '$Role' access on the site." -ForegroundColor Green
}

Write-Host ''
Write-Host 'Done. The Logic App identity can now archive approved documents to this SharePoint site via Microsoft Graph.' -ForegroundColor Green
Write-Host 'No client secret was used at any point -- authorization is entirely managed-identity + Graph app-role based.'

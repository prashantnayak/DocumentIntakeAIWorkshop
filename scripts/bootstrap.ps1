#Requires -Modules Az.Accounts, Az.Resources
<#
.SYNOPSIS
    One-time bootstrap for the Document Intake AI workload: creates the
    resource group (idempotent -- infra/main.bicep also creates it, so this is
    safe to skip if you prefer letting the first deployment create it), an
    Entra ID App Registration with a GitHub Actions OIDC federated credential
    per environment, and the SUBSCRIPTION-SCOPED role assignments CI/CD needs
    to deploy without any stored client secret.

.DESCRIPTION
    Run this once per environment before the first `deploy.yml` run. It does
    NOT deploy any application resources (Storage, Functions, SQL, etc.) --
    that is infra/main.bicep's job, run by the pipeline.

    ROLE SCOPE -- WHY SUBSCRIPTION AND NOT RESOURCE GROUP
    infra/main.bicep uses `targetScope = 'subscription'`: it creates the
    resource group itself, and it also deploys two subscription-scoped
    modules (governance-policy.bicep and defender.bicep). A Contributor
    assignment limited to the resource group therefore cannot run the
    deployment at all -- `az deployment sub create` fails on
    Microsoft.Resources/deployments/write at subscription scope before it
    reaches a single resource.

    ROLE SET -- WHY TWO ROLES
      * Contributor (subscription scope) -- create/modify every resource in
        the workload, plus the resource group and the subscription-scoped
        deployment itself. Contributor explicitly CANNOT create role
        assignments.
      * Role Based Access Control Administrator (subscription scope) -- the
        template assigns roughly twenty data-plane RBAC roles (Storage Blob
        Data Contributor/Reader/Delegator/Owner, Key Vault Crypto Service
        Encryption User/Secrets User, Cognitive
        Services User, Monitoring Metrics Publisher). Without a role that can
        write Microsoft.Authorization/roleAssignments, the deployment fails
        with AuthorizationFailed partway through, leaving a half-built
        environment. This role can manage access but -- unlike User Access
        Administrator -- cannot itself grant arbitrary non-RBAC permissions,
        so it is the least-privilege choice of the two. Pass
        -UseUserAccessAdministrator to fall back to User Access Administrator
        for tenants where the RBAC Administrator role is unavailable.

    Both are genuinely privileged. The script therefore prints an explicit
    warning, honours -WhatIf/-Confirm through ShouldProcess, and never widens
    an assignment that already exists.

.PARAMETER SubscriptionId
    Target Azure subscription ID.

.PARAMETER ResourceGroupName
    Resource group name that infra/main.bicep will create/manage (must match
    the name your naming convention produces, e.g. rg-intakeai-dev-eus2).

.PARAMETER Location
    Azure region, e.g. eastus2.

.PARAMETER GitHubOrg
    GitHub organization or user that owns the repository.

.PARAMETER GitHubRepo
    Repository name, e.g. DocumentIntakeAIWorkshop.

.PARAMETER GitHubEnvironment
    GitHub environment name this federated credential authorizes (e.g. dev,
    test, prod). Run once per environment with a different value.

.PARAMETER AppRegistrationDisplayName
    Display name for the Entra ID App Registration used as the OIDC identity.

.PARAMETER UseUserAccessAdministrator
    Assign 'User Access Administrator' instead of 'Role Based Access Control
    Administrator'. Only use this if the RBAC Administrator role is not
    available in your tenant -- it is strictly broader.

.EXAMPLE
    ./bootstrap.ps1 -SubscriptionId 00000000-0000-0000-0000-000000000000 `
        -ResourceGroupName rg-intakeai-dev-eus2 -Location eastus2 `
        -GitHubOrg contoso -GitHubRepo DocumentIntakeAIWorkshop -GitHubEnvironment dev

.EXAMPLE
    # Preview exactly which identities and role assignments would be created.
    ./bootstrap.ps1 -SubscriptionId ... -ResourceGroupName ... -Location eastus2 `
        -GitHubOrg contoso -GitHubRepo DocumentIntakeAIWorkshop -GitHubEnvironment dev -WhatIf
#>
[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High')]
param(
    [Parameter(Mandatory = $true)]
    [string]$SubscriptionId,

    [Parameter(Mandatory = $true)]
    [string]$ResourceGroupName,

    [Parameter(Mandatory = $true)]
    [string]$Location,

    [Parameter(Mandatory = $true)]
    [string]$GitHubOrg,

    [Parameter(Mandatory = $true)]
    [string]$GitHubRepo,

    [Parameter(Mandatory = $true)]
    [ValidateSet('dev', 'test', 'prod')]
    [string]$GitHubEnvironment,

    [string]$AppRegistrationDisplayName = "spn-intakeai-github-$GitHubEnvironment",

    [switch]$UseUserAccessAdministrator
)

$ErrorActionPreference = 'Stop'

$accessAdminRole = if ($UseUserAccessAdministrator) { 'User Access Administrator' } else { 'Role Based Access Control Administrator' }
$subscriptionScope = "/subscriptions/$SubscriptionId"
$requiredRoles = @('Contributor', $accessAdminRole)

Write-Host "Connecting to Azure subscription $SubscriptionId ..." -ForegroundColor Cyan
if (-not (Get-AzContext)) {
    Connect-AzAccount -Subscription $SubscriptionId | Out-Null
}
Set-AzContext -Subscription $SubscriptionId | Out-Null

Write-Host ''
Write-Warning @"
This script grants the CI/CD service principal the following SUBSCRIPTION-SCOPED roles:
  * Contributor
  * $accessAdminRole
Both are privileged. Contributor alone cannot run this workload's deployment:
infra/main.bicep is subscription-scoped (it creates the resource group and the
feature-flagged policy/Defender modules) and it creates role assignments, which
Contributor is explicitly not permitted to do. Review the rationale in the
.DESCRIPTION above and in README.md before continuing. Re-run with -WhatIf to
preview without changing anything.
"@
Write-Host ''

Write-Host "Ensuring resource group '$ResourceGroupName' exists in $Location ..." -ForegroundColor Cyan
$rg = Get-AzResourceGroup -Name $ResourceGroupName -ErrorAction SilentlyContinue
if (-not $rg) {
    if ($PSCmdlet.ShouldProcess($ResourceGroupName, 'Create resource group')) {
        New-AzResourceGroup -Name $ResourceGroupName -Location $Location -Tag @{ DataClassification = 'PHI' } | Out-Null
        Write-Host "Created resource group $ResourceGroupName." -ForegroundColor Green
    }
}
else {
    Write-Host "Resource group $ResourceGroupName already exists -- leaving as-is." -ForegroundColor Yellow
}

Write-Host "Ensuring Entra ID app registration '$AppRegistrationDisplayName' exists ..." -ForegroundColor Cyan
$app = Get-AzADApplication -DisplayName $AppRegistrationDisplayName -ErrorAction SilentlyContinue
if (-not $app) {
    if ($PSCmdlet.ShouldProcess($AppRegistrationDisplayName, 'Create Entra ID application')) {
        $app = New-AzADApplication -DisplayName $AppRegistrationDisplayName
        Write-Host "Created application $($app.AppId)." -ForegroundColor Green
    }
}
else {
    Write-Host "Application $($app.AppId) already exists -- leaving as-is." -ForegroundColor Yellow
}

if (-not $app) {
    Write-Host 'No application object available (-WhatIf run) -- skipping the remaining steps.' -ForegroundColor Yellow
    return
}

$sp = Get-AzADServicePrincipal -ApplicationId $app.AppId -ErrorAction SilentlyContinue
if (-not $sp) {
    if ($PSCmdlet.ShouldProcess($app.AppId, 'Create service principal')) {
        $sp = New-AzADServicePrincipal -ApplicationId $app.AppId
        Write-Host "Created service principal $($sp.Id)." -ForegroundColor Green
    }
}

$federatedCredentialName = "github-$GitHubOrg-$GitHubRepo-$GitHubEnvironment"
$subject = "repo:$GitHubOrg/${GitHubRepo}:environment:$GitHubEnvironment"

Write-Host "Ensuring GitHub OIDC federated credential '$federatedCredentialName' exists (subject: $subject) ..." -ForegroundColor Cyan
$existingCredential = Get-AzADAppFederatedCredential -ApplicationObjectId $app.Id -ErrorAction SilentlyContinue |
    Where-Object { $_.Name -eq $federatedCredentialName }

if (-not $existingCredential) {
    if ($PSCmdlet.ShouldProcess($federatedCredentialName, 'Create federated identity credential')) {
        New-AzADAppFederatedCredential -ApplicationObjectId $app.Id `
            -Name $federatedCredentialName `
            -Issuer 'https://token.actions.githubusercontent.com' `
            -Subject $subject `
            -Audience 'api://AzureADTokenExchange' | Out-Null
        Write-Host 'Created federated identity credential -- no client secret was created or stored.' -ForegroundColor Green
    }
}
else {
    Write-Host 'Federated identity credential already exists -- leaving as-is.' -ForegroundColor Yellow
}

if (-not $sp) {
    Write-Host 'No service principal object available (-WhatIf run) -- skipping role assignments.' -ForegroundColor Yellow
    return
}

foreach ($roleName in $requiredRoles) {
    Write-Host "Ensuring role assignment '$roleName' at scope $subscriptionScope ..." -ForegroundColor Cyan

    $roleDefinition = Get-AzRoleDefinition -Name $roleName -ErrorAction SilentlyContinue
    if (-not $roleDefinition) {
        throw "Role definition '$roleName' was not found in this tenant. If '$roleName' is 'Role Based Access Control Administrator', re-run with -UseUserAccessAdministrator."
    }

    $existingAssignment = Get-AzRoleAssignment -ObjectId $sp.Id -Scope $subscriptionScope -RoleDefinitionName $roleName -ErrorAction SilentlyContinue |
        Where-Object { $_.Scope -eq $subscriptionScope }

    if ($existingAssignment) {
        Write-Host "  Role assignment already exists at this exact scope -- leaving as-is." -ForegroundColor Yellow
        continue
    }

    if ($PSCmdlet.ShouldProcess("$($sp.Id) -> $roleName", "Assign at $subscriptionScope")) {
        New-AzRoleAssignment -ObjectId $sp.Id -RoleDefinitionName $roleName -Scope $subscriptionScope | Out-Null
        Write-Host "  Assigned $roleName at $subscriptionScope." -ForegroundColor Green
    }
}

Write-Host ''
Write-Host 'Bootstrap complete. Configure the following as GitHub environment secrets:' -ForegroundColor Cyan
Write-Host "  AZURE_CLIENT_ID          = $($app.AppId)"
Write-Host "  AZURE_TENANT_ID          = $((Get-AzContext).Tenant.Id)"
Write-Host "  AZURE_SUBSCRIPTION_ID    = $SubscriptionId"
Write-Host "  AZURE_DEPLOYER_OBJECT_ID = $($sp.Id)"
Write-Host ''
Write-Host 'AZURE_DEPLOYER_OBJECT_ID is the service principal OBJECT id (not the app/client id).' -ForegroundColor Cyan
Write-Host 'deploy.yml passes it to infra/main.bicep so the deployment principal gets Storage Blob'
Write-Host 'Data Contributor scoped to the private deployment-artifacts container ONLY, which is how'
Write-Host 'the code-deploy job publishes the Function and Logic App packages.'
Write-Host ''
Write-Host 'No client secret is required -- authentication uses the OIDC federated credential above.' -ForegroundColor Green
Write-Host 'Repeat this script once per environment (dev/test/prod) with a different -GitHubEnvironment value before enabling that environment''s deploy pipeline.'

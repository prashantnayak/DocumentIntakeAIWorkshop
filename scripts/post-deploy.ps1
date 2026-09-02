#Requires -Modules SqlServer, Az.Accounts
<#
.SYNOPSIS
    Post-deploy steps for the Document Intake AI workload: runs the SQL
    migrations (substituting the real managed identity/Entra group names),
    seeds nothing PHI-related (there is none to seed), and prints the manual
    steps that cannot be automated (Office 365 connection consent, SharePoint
    Graph permissions).

.PARAMETER SqlServerFqdn
    Fully-qualified SQL logical server name (from the `sqlServerFqdn` Bicep output).

.PARAMETER DatabaseName
    Database name (from the `sql.outputs.databaseName` Bicep output, e.g. sqldb-intake).

.PARAMETER FunctionAppIdentityName
    Name of the Function App's user-assigned managed identity (e.g. id-func-intakeai-dev-eus2).

.PARAMETER LogicAppIdentityName
    Name of the Logic App's user-assigned managed identity (e.g. id-logic-intakeai-dev-eus2).

.PARAMETER ReviewerGroupName
    Display name of the reviewer Entra ID group.

.PARAMETER SupervisorGroupName
    Display name of the supervisor Entra ID group.

.EXAMPLE
    ./post-deploy.ps1 -SqlServerFqdn sql-intakeai-dev-eus2-abc1234.database.windows.net `
        -DatabaseName sqldb-intake `
        -FunctionAppIdentityName id-func-intakeai-dev-eus2 `
        -LogicAppIdentityName id-logic-intakeai-dev-eus2 `
        -ReviewerGroupName sg-intakeai-reviewers `
        -SupervisorGroupName sg-intakeai-supervisors
#>
[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [Parameter(Mandatory = $true)]
    [string]$SqlServerFqdn,

    [Parameter(Mandatory = $true)]
    [string]$DatabaseName,

    [Parameter(Mandatory = $true)]
    [string]$FunctionAppIdentityName,

    [Parameter(Mandatory = $true)]
    [string]$LogicAppIdentityName,

    [Parameter(Mandatory = $true)]
    [string]$ReviewerGroupName,

    [Parameter(Mandatory = $true)]
    [string]$SupervisorGroupName
)

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $PSScriptRoot
$migrationsPath = Join-Path $repoRoot 'sql\migrations'

Write-Host 'Acquiring an Entra ID access token for Azure SQL ...' -ForegroundColor Cyan
if (-not (Get-AzContext)) {
    Connect-AzAccount | Out-Null
}
$accessToken = (Get-AzAccessToken -ResourceUrl 'https://database.windows.net/').Token

$migrationFiles = Get-ChildItem -Path $migrationsPath -Filter '*.sql' | Sort-Object Name
foreach ($file in $migrationFiles) {
    Write-Host "Applying migration $($file.Name) ..." -ForegroundColor Cyan

    $sqlText = Get-Content -Path $file.FullName -Raw

    # 004_users_and_permissions.sql ships with human-readable placeholders;
    # substitute the real identity/group display names for this environment.
    if ($file.Name -eq '004_users_and_permissions.sql') {
        $sqlText = $sqlText.Replace('<function-app-identity-name>', $FunctionAppIdentityName)
        $sqlText = $sqlText.Replace('<logic-app-user-assigned-identity-name>', $LogicAppIdentityName)
        $sqlText = $sqlText.Replace('<reviewer-entra-group-name>', $ReviewerGroupName)
        $sqlText = $sqlText.Replace('<supervisor-entra-group-name>', $SupervisorGroupName)
    }

    if ($PSCmdlet.ShouldProcess($file.Name, 'Invoke-Sqlcmd')) {
        # GO batch separators are handled natively by Invoke-Sqlcmd.
        Invoke-Sqlcmd -ServerInstance $SqlServerFqdn -Database $DatabaseName -AccessToken $accessToken -Query $sqlText -Verbose:$false -ErrorAction Stop | Out-Null
    }

    Write-Host "  Applied $($file.Name)." -ForegroundColor Green
}

Write-Host ''
Write-Host '===================================================================' -ForegroundColor Yellow
Write-Host ' Manual steps that CANNOT be automated by Bicep/ARM or this script:' -ForegroundColor Yellow
Write-Host '===================================================================' -ForegroundColor Yellow
Write-Host '1. Office 365 Outlook connection consent (required before the human-approval-workflow can send mail):'
Write-Host '   Azure Portal -> Logic App -> API connections -> office365 -> Edit API connection -> Authorize -> sign in as the reviewer mailbox/service account.'
Write-Host ''
Write-Host '2. If enableSharePointArchive is true, grant the Logic App user-assigned identity Graph application permissions'
Write-Host '   (Sites.Selected recommended for least privilege) -- run scripts/grant-graph-permissions.ps1.'
Write-Host ''
Write-Host '3. Confirm the Entra SQL admin group, reviewer group, and supervisor group object IDs in infra/params/*.bicepparam'
Write-Host '   match real Entra ID groups with the correct membership before go-live.'
Write-Host ''
Write-Host '4. (Optional) Follow sql/always-encrypted/README.md if you want Always Encrypted in addition to the Dynamic Data'
Write-Host '   Masking already applied by migration 002.'

#Requires -Modules SqlServer, Az.Accounts
<#
.SYNOPSIS
    Implements the Always Encrypted upgrade plan documented in
    sql/always-encrypted/README.md for dbo.Documents. Opt-in, not run by
    default post-deploy -- see the README for the connector-compatibility
    prerequisite before running this against an environment where Logic Apps
    writes to dbo.Documents directly.

.PARAMETER SqlServerFqdn
    Fully-qualified SQL logical server name, e.g. sql-intakeai-dev-eus2-xxxxx.database.windows.net

.PARAMETER DatabaseName
    Database name, e.g. sqldb-intake

.PARAMETER KeyVaultKeyUri
    Versioned Key Vault key URI dedicated to Always Encrypted (do not reuse the TDE protector key).

.EXAMPLE
    ./configure-always-encrypted.ps1 -SqlServerFqdn sql-intakeai-dev-eus2-abc1234.database.windows.net `
        -DatabaseName sqldb-intake `
        -KeyVaultKeyUri "https://kv-intakeai-dev-eus2.vault.azure.net/keys/cmk-ae-documents/abcdef1234567890abcdef1234567890"
#>
[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [Parameter(Mandatory = $true)]
    [string]$SqlServerFqdn,

    [Parameter(Mandatory = $true)]
    [string]$DatabaseName,

    [Parameter(Mandatory = $true)]
    [string]$KeyVaultKeyUri,

    [string]$ColumnMasterKeyName = 'CMK_IntakeAI_Documents',

    [string]$ColumnEncryptionKeyName = 'CEK_IntakeAI_Documents',

    [string]$LogFileDirectory = (Join-Path $PSScriptRoot 'logs')
)

$ErrorActionPreference = 'Stop'

Write-Host "Always Encrypted setup for $DatabaseName on $SqlServerFqdn" -ForegroundColor Cyan
Write-Host 'Prerequisite check: confirm the Logic Apps SQL connector compatibility caveat in README.md has been addressed.' -ForegroundColor Yellow
$confirmation = Read-Host 'Type YES to continue'
if ($confirmation -ne 'YES') {
    Write-Host 'Aborted by operator.' -ForegroundColor Yellow
    exit 0
}

if (-not (Test-Path $LogFileDirectory)) {
    New-Item -ItemType Directory -Path $LogFileDirectory -Force | Out-Null
}

Write-Host 'Connecting to Azure (Entra ID) ...'
$null = Get-AzContext -ErrorAction SilentlyContinue
if (-not (Get-AzContext)) {
    Connect-AzAccount | Out-Null
}

Write-Host 'Building column master key settings (Azure Key Vault) ...'
$cmkSettings = New-SqlColumnMasterKeySettings -KeyStoreProviderName 'AZURE_KEY_VAULT' -KeyPath $KeyVaultKeyUri

Write-Host 'Connecting to the target database ...'
$database = Get-SqlDatabase -ServerInstance $SqlServerFqdn -DatabaseName $DatabaseName

Write-Host "Creating column master key '$ColumnMasterKeyName' ..."
if ($PSCmdlet.ShouldProcess($ColumnMasterKeyName, 'New-SqlColumnMasterKey')) {
    New-SqlColumnMasterKey -Name $ColumnMasterKeyName -InputObject $database -ColumnMasterKeySettings $cmkSettings
}

Write-Host "Creating column encryption key '$ColumnEncryptionKeyName' ..."
if ($PSCmdlet.ShouldProcess($ColumnEncryptionKeyName, 'New-SqlColumnEncryptionKey')) {
    New-SqlColumnEncryptionKey -Name $ColumnEncryptionKeyName -InputObject $database -ColumnMasterKeyName $ColumnMasterKeyName
}

Write-Host 'Dropping Dynamic Data Masking from the target columns (Always Encrypted and DDM cannot coexist on the same column) ...'
$dropMaskingSql = @'
ALTER TABLE dbo.Documents ALTER COLUMN PatientIdentifier NVARCHAR(200) NULL;
ALTER TABLE dbo.Documents ALTER COLUMN DateOfService NVARCHAR(50) NULL;
ALTER TABLE dbo.Documents ALTER COLUMN Provider NVARCHAR(400) NULL;
ALTER TABLE dbo.Documents ALTER COLUMN ExtractedFieldsJson NVARCHAR(MAX) NULL;
'@
if ($PSCmdlet.ShouldProcess('dbo.Documents', 'Drop MASKED WITH clauses')) {
    Invoke-Sqlcmd -ServerInstance $SqlServerFqdn -Database $DatabaseName -Query $dropMaskingSql -AccessToken (Get-AzAccessToken -ResourceUrl 'https://database.windows.net/').Token
}

Write-Host 'Defining per-column encryption settings ...'
$columnSettings = @(
    New-SqlColumnEncryptionSettings -ColumnName 'PatientIdentifier'   -SchemaName 'dbo' -TableName 'Documents' -EncryptionType 'Deterministic' -EncryptionKeyName $ColumnEncryptionKeyName
    New-SqlColumnEncryptionSettings -ColumnName 'DateOfService'       -SchemaName 'dbo' -TableName 'Documents' -EncryptionType 'Deterministic' -EncryptionKeyName $ColumnEncryptionKeyName
    New-SqlColumnEncryptionSettings -ColumnName 'Provider'            -SchemaName 'dbo' -TableName 'Documents' -EncryptionType 'Randomized'     -EncryptionKeyName $ColumnEncryptionKeyName
    New-SqlColumnEncryptionSettings -ColumnName 'ExtractedFieldsJson' -SchemaName 'dbo' -TableName 'Documents' -EncryptionType 'Randomized'     -EncryptionKeyName $ColumnEncryptionKeyName
)

Write-Host 'Applying Always Encrypted (this rewrites the table; expect locking proportional to row count) ...' -ForegroundColor Yellow
if ($PSCmdlet.ShouldProcess('dbo.Documents', 'Set-SqlColumnEncryption')) {
    Set-SqlColumnEncryption -InputObject $database -ColumnEncryptionSettings $columnSettings -LogFileDirectory $LogFileDirectory
}

Write-Host 'Done. Remember to add "Column Encryption Setting=Enabled" to any client connection string that reads/writes these columns.' -ForegroundColor Green

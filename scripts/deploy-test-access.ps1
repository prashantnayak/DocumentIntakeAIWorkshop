<#
.SYNOPSIS
    Deploys the optional private Windows workshop VM and Developer Bastion.

.DESCRIPTION
    Reuses the validated subscription-scoped infrastructure template, enables
    only the optional test-access resources, generates a temporary local-admin
    password, and grants the signed-in Entra user VM Administrator Login.
    The password is copied to the Windows clipboard and is never written to the
    repository or emitted as an ARM deployment output.
#>
[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [Parameter(Mandatory = $true)]
    [string]$SubscriptionId,

    [Parameter(Mandatory = $true)]
    [string]$ParametersFile,

    [string]$Location = 'swedencentral'
)

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $PSScriptRoot
$templateFile = Join-Path $repoRoot 'infra\main.bicep'
$resolvedParametersFile = (Resolve-Path $ParametersFile).Path
$deploymentName = "intakeai-test-access-$(Get-Date -Format 'yyyyMMdd-HHmmss')"

function Get-SignedInUserObjectId {
    $token = az account get-access-token --resource https://management.azure.com/ --query accessToken --output tsv
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($token)) {
        throw 'Unable to acquire an Azure Resource Manager token. Run az login and retry.'
    }

    $payload = $token.Split('.')[1].Replace('-', '+').Replace('_', '/')
    $payload += '=' * ((4 - ($payload.Length % 4)) % 4)
    $claims = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($payload)) | ConvertFrom-Json
    if ([string]::IsNullOrWhiteSpace($claims.oid)) {
        throw 'The signed-in Azure token does not contain a user object ID. Sign in with a tenant member account and retry.'
    }

    return $claims.oid
}

$administratorObjectId = Get-SignedInUserObjectId
$temporaryPassword = "T!9$([guid]::NewGuid().ToString('N'))z"
$temporaryParametersFile = Join-Path $env:TEMP "$deploymentName.parameters.json"

try {
    @{
        '$schema' = 'https://schema.management.azure.com/schemas/2019-04-01/deploymentParameters.json#'
        contentVersion = '1.0.0.0'
        parameters = @{
            enableTestAccess = @{ value = $true }
            testVmAdminPassword = @{ value = $temporaryPassword }
            testVmAdministratorObjectId = @{ value = $administratorObjectId.Trim() }
            documentIntelligenceStudioUserObjectId = @{ value = $administratorObjectId.Trim() }
        }
    } | ConvertTo-Json -Depth 8 | Set-Content -Path $temporaryParametersFile -Encoding utf8NoBOM

    if ($PSCmdlet.ShouldProcess('Private Windows test VM and Developer Bastion', 'Deploy')) {
        az account set --subscription $SubscriptionId
        if ($LASTEXITCODE -ne 0) { throw 'Unable to select the requested Azure subscription.' }

        az deployment sub create `
            --name $deploymentName `
            --location $Location `
            --template-file $templateFile `
            --parameters "@$resolvedParametersFile" "@$temporaryParametersFile" `
            --subscription $SubscriptionId `
            --output none

        if ($LASTEXITCODE -ne 0) { throw "Deployment '$deploymentName' failed." }

        Set-Clipboard -Value $temporaryPassword
        Write-Host "Deployment '$deploymentName' succeeded." -ForegroundColor Green
        Write-Host 'Temporary local-admin password copied to your clipboard.' -ForegroundColor Yellow
        Write-Host 'Username: testadmin'
        Write-Host 'Connect in Azure portal: Virtual machine -> Connect -> Bastion.'
    }
}
finally {
    if (Test-Path $temporaryParametersFile) {
        Remove-Item -Path $temporaryParametersFile -Force
    }
    $temporaryPassword = $null
}

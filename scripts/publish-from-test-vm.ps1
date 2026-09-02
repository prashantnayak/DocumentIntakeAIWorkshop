#Requires -Version 5.1
<#
.SYNOPSIS
    Publishes the private Function and Logic App packages from the workshop VM.

.DESCRIPTION
    Runs on the VNet-connected Windows test VM using its managed identity.
    The identity must temporarily have Storage Blob Data Contributor on the
    deployment-artifacts container, Website Contributor on both app sites, and
    Key Vault Secrets Officer on the callback vault.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$SubscriptionId,

    [Parameter(Mandatory = $true)]
    [string]$ResourceGroupName,

    [Parameter(Mandatory = $true)]
    [string]$FunctionAppName,

    [Parameter(Mandatory = $true)]
    [string]$LogicAppName,

    [Parameter(Mandatory = $true)]
    [string]$ArtifactsStorageAccountName,

    [Parameter(Mandatory = $true)]
    [string]$ArtifactsContainerName,

    [Parameter(Mandatory = $true)]
    [string]$KeyVaultName,

    [Parameter(Mandatory = $true)]
    [string]$CallbackSecretName,

    [Parameter(Mandatory = $true)]
    [uri]$FunctionPackageUri,

    [Parameter(Mandatory = $true)]
    [uri]$LogicAppPackageUri,

    [Parameter(Mandatory = $true)]
    [ValidatePattern('^[a-fA-F0-9]{64}$')]
    [string]$FunctionPackageSha256,

    [Parameter(Mandatory = $true)]
    [ValidatePattern('^[a-fA-F0-9]{64}$')]
    [string]$LogicAppPackageSha256
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$workPath = 'C:\AzureData\IntakeDeployment'
New-Item -ItemType Directory -Path $workPath -Force | Out-Null
$functionPackagePath = Join-Path $workPath 'function-app.zip'
$logicAppPackagePath = Join-Path $workPath 'logic-app.zip'

Invoke-WebRequest -Uri $FunctionPackageUri -OutFile $functionPackagePath -UseBasicParsing
Invoke-WebRequest -Uri $LogicAppPackageUri -OutFile $logicAppPackagePath -UseBasicParsing

if ((Get-FileHash $functionPackagePath -Algorithm SHA256).Hash.ToLowerInvariant() -ne $FunctionPackageSha256.ToLowerInvariant()) {
    throw 'Function package hash mismatch.'
}
if ((Get-FileHash $logicAppPackagePath -Algorithm SHA256).Hash.ToLowerInvariant() -ne $LogicAppPackageSha256.ToLowerInvariant()) {
    throw 'Logic App package hash mismatch.'
}

Install-PackageProvider -Name NuGet -MinimumVersion 2.8.5.201 -Force | Out-Null
Set-PSRepository -Name PSGallery -InstallationPolicy Trusted
Install-Module -Name Az.Storage, Az.Websites, Az.KeyVault -Scope AllUsers -Force -AllowClobber
Connect-AzAccount -Identity -Subscription $SubscriptionId | Out-Null

$storageContext = New-AzStorageContext `
    -StorageAccountName $ArtifactsStorageAccountName `
    -UseConnectedAccount
$functionBlobName = "function-app/$($FunctionPackageSha256.ToLowerInvariant()).zip"
$logicAppBlobName = "logic-app/$($LogicAppPackageSha256.ToLowerInvariant()).zip"
$functionPackageUrl = "https://$ArtifactsStorageAccountName.blob.core.windows.net/$ArtifactsContainerName/$functionBlobName"
$uploaded = $false
for ($attempt = 1; $attempt -le 12 -and -not $uploaded; $attempt++) {
    try {
        Set-AzStorageBlobContent `
            -File $functionPackagePath `
            -Container $ArtifactsContainerName `
            -Blob $functionBlobName `
            -Context $storageContext `
            -Force | Out-Null
        Set-AzStorageBlobContent `
            -File $logicAppPackagePath `
            -Container $ArtifactsContainerName `
            -Blob $logicAppBlobName `
            -Context $storageContext `
            -Force | Out-Null
        $uploaded = $true
    }
    catch {
        if ($attempt -eq 12) {
            throw
        }
        Start-Sleep -Seconds 30
    }
}

Publish-AzWebApp `
    -ResourceGroupName $ResourceGroupName `
    -Name $LogicAppName `
    -ArchivePath $logicAppPackagePath `
    -Force | Out-Null

$expectedWorkflows = @(
    'business-rules-workflow'
    'human-approval-workflow'
    'sla-notification-workflow'
)
$workflowPath = "/subscriptions/$SubscriptionId/resourceGroups/$ResourceGroupName/providers/Microsoft.Web/sites/$LogicAppName/workflows?api-version=2018-11-01"
$workflowsReady = $false
for ($attempt = 1; $attempt -le 10 -and -not $workflowsReady; $attempt++) {
    try {
        $workflowResponse = Invoke-AzRestMethod -Method GET -Path $workflowPath
        $workflowNames = @((ConvertFrom-Json $workflowResponse.Content).value.name)
        $missingWorkflows = @($expectedWorkflows | Where-Object { $_ -notin $workflowNames })
        $workflowsReady = $missingWorkflows.Count -eq 0
    }
    catch {
        $workflowsReady = $false
    }
    if (-not $workflowsReady) {
        Start-Sleep -Seconds 30
    }
}
if (-not $workflowsReady) {
    throw "Logic App workflows did not load: $($missingWorkflows -join ', ')"
}

$callbackPath = "/subscriptions/$SubscriptionId/resourceGroups/$ResourceGroupName/providers/Microsoft.Web/sites/$LogicAppName/hostruntime/runtime/webhooks/workflow/api/management/workflows/business-rules-workflow/triggers/Receive_processing_request/listCallbackUrl?api-version=2018-11-01"
$callbackResponse = Invoke-AzRestMethod -Method POST -Path $callbackPath
$callbackUrl = (ConvertFrom-Json $callbackResponse.Content).value
if ([string]::IsNullOrWhiteSpace($callbackUrl)) {
    throw 'The business-rules workflow returned an empty callback URL.'
}

Set-AzKeyVaultSecret `
    -VaultName $KeyVaultName `
    -Name $CallbackSecretName `
    -SecretValue (ConvertTo-SecureString $callbackUrl -AsPlainText -Force) | Out-Null

$appSettingsPath = "/subscriptions/$SubscriptionId/resourceGroups/$ResourceGroupName/providers/Microsoft.Web/sites/$FunctionAppName/config/appsettings/list?api-version=2022-03-01"
$appSettingsResponse = Invoke-AzRestMethod -Method POST -Path $appSettingsPath
$appSettings = (ConvertFrom-Json $appSettingsResponse.Content).properties
$appSettings | Add-Member `
    -MemberType NoteProperty `
    -Name WEBSITE_RUN_FROM_PACKAGE `
    -Value $functionPackageUrl `
    -Force
$updateSettingsPath = "/subscriptions/$SubscriptionId/resourceGroups/$ResourceGroupName/providers/Microsoft.Web/sites/$FunctionAppName/config/appsettings?api-version=2022-03-01"
Invoke-AzRestMethod `
    -Method PUT `
    -Path $updateSettingsPath `
    -Payload (@{ properties = $appSettings } | ConvertTo-Json -Depth 10) | Out-Null

Restart-AzWebApp -ResourceGroupName $ResourceGroupName -Name $FunctionAppName | Out-Null
$syncPath = "/subscriptions/$SubscriptionId/resourceGroups/$ResourceGroupName/providers/Microsoft.Web/sites/$FunctionAppName/syncfunctiontriggers?api-version=2022-03-01"
$synced = $false
for ($attempt = 1; $attempt -le 10 -and -not $synced; $attempt++) {
    try {
        Invoke-AzRestMethod -Method POST -Path $syncPath | Out-Null
        $synced = $true
    }
    catch {
        if ($attempt -eq 10) {
            throw
        }
        Start-Sleep -Seconds 30
    }
}

$expectedFunctions = @(
    'CompensateDocument'
    'DocumentOrchestrator'
    'FinalizeSource'
    'InvokeBusinessWorkflow'
    'PollIncomingDocuments'
    'PollProcessingStatus'
    'ProcessAndStage'
    'ReconcileStaleDocuments'
)
$functionsPath = "/subscriptions/$SubscriptionId/resourceGroups/$ResourceGroupName/providers/Microsoft.Web/sites/$FunctionAppName/functions?api-version=2022-03-01"
$functionsReady = $false
for ($attempt = 1; $attempt -le 10 -and -not $functionsReady; $attempt++) {
    $functionResponse = Invoke-AzRestMethod -Method GET -Path $functionsPath
    $functionNames = @((ConvertFrom-Json $functionResponse.Content).value.properties.name)
    if (-not $functionNames) {
        $functionNames = @((ConvertFrom-Json $functionResponse.Content).value.name | ForEach-Object { ($_ -split '/')[-1] })
    }
    $missingFunctions = @($expectedFunctions | Where-Object { $_ -notin $functionNames })
    $functionsReady = $missingFunctions.Count -eq 0
    if (-not $functionsReady) {
        Start-Sleep -Seconds 30
    }
}
if (-not $functionsReady) {
    throw "Function App did not load expected functions: $($missingFunctions -join ', ')"
}

Write-Output 'DEPLOYMENT_OK'
Write-Output "WORKFLOWS=$($workflowNames -join ',')"
Write-Output "FUNCTIONS=$($functionNames -join ',')"
Write-Output "FUNCTION_PACKAGE_SHA256=$($FunctionPackageSha256.ToLowerInvariant())"
Write-Output "LOGIC_PACKAGE_SHA256=$($LogicAppPackageSha256.ToLowerInvariant())"
Write-Output 'PACKAGES_UPLOADED=true'
Write-Output 'CALLBACK_ROTATED=true'

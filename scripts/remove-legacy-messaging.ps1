[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
param(
    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string] $ResourceGroupName,

    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string] $LegacyFunctionAppName,

    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string] $LegacyFunctionPlanName,

    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string] $LegacyLogicAppName,

    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string] $ServiceBusNamespaceName,

    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string] $EventGridSystemTopicName,

    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string] $EventGridEventSubscriptionName,

    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string] $EventGridIdentityName,

    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string] $PhiStorageAccountName,

    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string] $EventGridDeadLetterContainerName,

    [Parameter(Mandatory)]
    [switch] $IntakePaused,

    [Parameter(Mandatory)]
    [switch] $QueuesDrained,

    [Parameter(Mandatory)]
    [switch] $NoActiveLegacyRuns,

    [Parameter(Mandatory)]
    [switch] $ReplacementSmokeTestPassed
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if (-not ($IntakePaused -and $QueuesDrained -and $NoActiveLegacyRuns -and $ReplacementSmokeTestPassed)) {
    throw 'All cutover gates must be explicitly supplied before any legacy resource can be removed.'
}

$subscriptionId = az account show --query id -o tsv
if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($subscriptionId)) {
    throw 'Unable to resolve the active Azure subscription. Run az login and select the intended subscription first.'
}

$baseId = "/subscriptions/$subscriptionId/resourceGroups/$ResourceGroupName/providers"
# Remove only the application subscription; Defender for Storage may share the
# system topic through its StorageAntimalwareSubscription.
$resources = @(
    @{
        Name = $LegacyFunctionAppName
        Id = "$baseId/Microsoft.Web/sites/$LegacyFunctionAppName"
    },
    @{
        Name = $LegacyLogicAppName
        Id = "$baseId/Microsoft.Web/sites/$LegacyLogicAppName"
    },
    @{
        Name = $LegacyFunctionPlanName
        Id = "$baseId/Microsoft.Web/serverfarms/$LegacyFunctionPlanName"
    },
    @{
        Name = $EventGridEventSubscriptionName
        Id = "$baseId/Microsoft.EventGrid/systemTopics/$EventGridSystemTopicName/eventSubscriptions/$EventGridEventSubscriptionName"
    },
    @{
        Name = $ServiceBusNamespaceName
        Id = "$baseId/Microsoft.ServiceBus/namespaces/$ServiceBusNamespaceName"
    },
    @{
        Name = $EventGridIdentityName
        Id = "$baseId/Microsoft.ManagedIdentity/userAssignedIdentities/$EventGridIdentityName"
    }
)

foreach ($resource in $resources) {
    $exists = az resource show --ids $resource.Id --query id -o tsv 2>$null
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($exists)) {
        Write-Verbose "Legacy resource '$($resource.Name)' is already absent."
        continue
    }

    if ($PSCmdlet.ShouldProcess($resource.Id, 'Delete exact legacy Azure resource')) {
        az resource delete --ids $resource.Id --only-show-errors
        if ($LASTEXITCODE -ne 0) {
            throw "Failed to delete legacy resource '$($resource.Id)'."
        }
    }
}

$containerTarget = "$PhiStorageAccountName/$EventGridDeadLetterContainerName"
if ($PSCmdlet.ShouldProcess($containerTarget, 'Delete exact Event Grid dead-letter container')) {
    az storage container delete `
        --account-name $PhiStorageAccountName `
        --name $EventGridDeadLetterContainerName `
        --auth-mode login `
        --only-show-errors | Out-Null
    if ($LASTEXITCODE -ne 0) {
        throw "Failed to delete legacy container '$containerTarget'."
    }
}

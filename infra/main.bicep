// Document Intake AI - subscription-scoped orchestration.
// Creates the resource group and calls every thin local module in
// dependency order. Contains no inline resource definitions -- every
// resource is created by a module in infra/modules/, each of which wraps a
// pinned Azure Verified Module (or, where no AVM module exists, a clearly
// commented raw ARM resource).
targetScope = 'subscription'

import { buildName, buildTags, buildAlphanumericName } from 'modules/naming.bicep'
import {
  resourceTagsType
  networkConfigType
  businessRulesConfigType
  logRetentionConfigType
  sqlDatabaseConfigType
  entraGroupsConfigType
  alertingConfigType
  sharePointArchiveConfigType
  governanceConfigType
} from 'types/shared-types.bicep'

// ---------------------------------------------------------------------------
// Core naming / environment parameters
// ---------------------------------------------------------------------------

@minLength(4)
@maxLength(20)
@description('Full Azure region name for every resource in this workload, e.g. swedencentral. All resources are pinned to a single region for this workshop environment.')
param location string

@minLength(2)
@maxLength(10)
@description('Short CAF region code used in resource names, e.g. swc for Sweden Central.')
param regionCode string

@minLength(2)
@maxLength(12)
@description('Short workload token used in every resource name, e.g. intakeai.')
param workloadName string

@allowed([
  'dev'
  'test'
  'prod'
])
@description('Deployment environment name. Only dev is exercised by this repository today; test/prod parameter files are intentionally not provided until those environments are approved (see docs/ASSUMPTIONS.md).')
param environmentName string

@description('Common resource tags (DataClassification, owner, cost center, etc.) applied to every module call.')
param tags resourceTagsType

// ---------------------------------------------------------------------------
// Network
// ---------------------------------------------------------------------------

@description('VNet address space and subnet sizing.')
param networkConfig networkConfigType

@description('Deploy the optional private Windows workshop VM and Developer Bastion access path.')
param enableTestAccess bool = false

@description('CIDR prefix for the optional private Windows test VM subnet.')
param testVmSubnetPrefix string = '10.60.2.0/24'

@description('Validated Azure VM SKU for the optional Windows test VM.')
param testVmSize string = 'Standard_D2s_v5'

@description('Local fallback administrator username for the optional test VM.')
param testVmAdminUsername string = 'testadmin'

@secure()
@description('Temporary local fallback administrator password. Required only when enableTestAccess is true.')
param testVmAdminPassword string = ''

@description('Entra user object ID granted Virtual Machine Administrator Login. Required only when enableTestAccess is true.')
param testVmAdministratorObjectId string = ''

@description('Optional Entra user object ID granted Cognitive Services User for interactive Studio testing.')
param documentIntelligenceStudioUserObjectId string = ''

// ---------------------------------------------------------------------------
// Key Vault
// ---------------------------------------------------------------------------

@minValue(7)
@maxValue(90)
@description('Key Vault soft-delete retention in days.')
param keyVaultSoftDeleteRetentionDays int

// ---------------------------------------------------------------------------
// Storage
// ---------------------------------------------------------------------------

@minValue(1)
@maxValue(365)
@description('PHI storage account blob/container soft-delete retention in days.')
param phiStorageSoftDeleteRetentionDays int

@description('Feature flag for time-based immutability (WORM) on the PHI documents container.')
param enableImmutabilityPolicy bool

@minValue(1)
@maxValue(146000)
@description('Immutability retention period in days, used only when enableImmutabilityPolicy is true.')
param immutabilityRetentionDays int

@minLength(3)
@maxLength(63)
@description('Name of the single PHI blob container. incoming/, processed/, and failed/ are virtual prefixes within this one container -- see docs/ASSUMPTIONS.md.')
param documentContainerName string = 'documents'

@minLength(1)
@maxLength(63)
@description('Name of the Azure Files content share dedicated to the Function App.')
param functionContentShareName string = 'func-content'

@minLength(1)
@maxLength(63)
@description('Name of the Azure Files content share dedicated to the Logic App.')
param logicAppContentShareName string = 'logic-content'

@minLength(3)
@maxLength(63)
@description('Name of the private container on the runtime storage account that holds application deployment packages. Never holds PHI. Published to by .github/workflows/deploy.yml from a VNet-joined runner and pulled by the Function App with its managed identity.')
param deploymentArtifactsContainerName string = 'deployment-artifacts'

@description('Object ID of the CI/CD service principal that publishes application deployment packages. Supplied from the AZURE_DEPLOYER_OBJECT_ID environment secret (printed by scripts/bootstrap.ps1); leave empty to skip the container-scoped Storage Blob Data Contributor grant.')
param deploymentArtifactsPublisherObjectId string = ''

@description('Blob path of the immutable Python Function package inside the deployment-artifacts container. CI supplies a SHA-256-addressed path.')
param functionPackageBlobName string = 'function-python/current.zip'

@allowed([
  'ServicePrincipal'
  'User'
  'Group'
])
@description('Microsoft Entra principal type for the deployment package publisher. CI uses ServicePrincipal; an interactive tenant deployment can use User.')
param deploymentArtifactsPublisherPrincipalType string = 'ServicePrincipal'

// ---------------------------------------------------------------------------
// Durable Blob intake
// ---------------------------------------------------------------------------

@description('Blob prefix polled by the Python Durable Blob trigger. Keep incoming-v2 during parallel validation, then switch to incoming at cutover.')
param functionIncomingPrefix string = 'incoming-v2'

@description('Versionless Key Vault secret name used to hold the signed business-rules Logic App callback URL.')
param businessRulesCallbackSecretName string = 'logic-business-rules-callback'

// ---------------------------------------------------------------------------
// Document Intelligence
// ---------------------------------------------------------------------------

@allowed([
  'F0'
  'S0'
])
@description('Document Intelligence pricing tier.')
param documentIntelligenceSkuName string

@minLength(1)
@description('Document Intelligence model ID used for extraction. Document Intelligence v4.0 (API version 2024-11-30) removed prebuilt-document; prebuilt-layout plus the keyValuePairs add-on feature is its replacement, and is what src/functions requests.')
param documentIntelligenceExtractionModelId string

@description('Document Intelligence custom classifier model ID. Leave empty to use the deterministic extraction-based fallback classifier described in docs/architecture.md.')
param documentIntelligenceClassifierModelId string

@description('Feature flag for customer-managed key encryption on the Document Intelligence account. Must be false on a first deployment: Microsoft documents that a Document Intelligence resource is always created with Microsoft-managed keys and CMK cannot be enabled on the create call. Re-deploy with true once the account exists. See infra/modules/document-intelligence.bicep and docs/COMPLIANCE.md.')
param enableDocumentIntelligenceCmk bool

// ---------------------------------------------------------------------------
// Compute (Function App + Logic App)
// ---------------------------------------------------------------------------

@allowed([
  'EP1'
  'EP2'
  'EP3'
])
@description('Elastic Premium plan SKU for the Function App.')
param functionAppSkuName string

@minValue(1)
@maxValue(20)
@description('Minimum (always-ready) Function App instance count.')
param functionMinimumInstanceCount int

@minValue(1)
@maxValue(20)
@description('Maximum burst-out Function App instance count.')
param functionMaximumElasticInstanceCount int

@minValue(1)
@maxValue(20)
@description('Logic Apps Standard (WS1) worker count.')
param logicAppWorkerCount int

@minValue(1)
@maxValue(168)
@description('Hours a generated user-delegation SAS link in a reviewer email remains valid. Must be >= businessRules.reviewEscalationAfterHours, otherwise the link a supervisor is asked to action at escalation time has already expired. Capped at 168 because a user delegation key is valid for at most 7 days.')
param sasLinkExpiryHours int

// ---------------------------------------------------------------------------
// Business rules
// ---------------------------------------------------------------------------

@description('Parameterized business-rule thresholds. The Logic Apps business-rules workflow is authoritative; the Function computes a deterministic fallback using the same values -- see docs/ASSUMPTIONS.md.')
param businessRules businessRulesConfigType

// ---------------------------------------------------------------------------
// SQL
// ---------------------------------------------------------------------------

@description('Azure SQL serverless compute and retention configuration.')
param sqlDatabaseConfig sqlDatabaseConfigType

@minLength(1)
@maxLength(63)
@description('Azure SQL database name.')
param sqlDatabaseName string = 'sqldb-intake'

@minLength(1)
@description('Name of a public SQL maintenance window configuration for the target region, e.g. SQL_EastUS2_DB_1. Verify availability for your region with: az maintenance public-configuration list.')
param maintenanceConfigurationName string

// ---------------------------------------------------------------------------
// Identity / access
// ---------------------------------------------------------------------------

@description('Entra ID group configuration for SQL administration and reviewer/supervisor access.')
param entraGroups entraGroupsConfigType

// ---------------------------------------------------------------------------
// Observability
// ---------------------------------------------------------------------------

@description('Log Analytics analytics vs. total (archive) retention configuration.')
param logRetention logRetentionConfigType

@description('Action group receiver configuration.')
param alerting alertingConfigType

@minValue(0)
@maxValue(4)
@description('Severity for dead-letter / Function-failure / AI-throttling alerts (0=critical .. 4=verbose).')
param criticalAlertSeverity int

@minValue(0)
@maxValue(4)
@description('Severity for the review-SLA escalation alert.')
param slaAlertSeverity int

@minValue(1)
@maxValue(100)
@description('Number of failed Key Vault data-plane operations within the evaluation window treated as an anomaly.')
param keyVaultAnomalyThreshold int

// ---------------------------------------------------------------------------
// Optional features
// ---------------------------------------------------------------------------

@description('Opt-in SharePoint Online archive feature configuration.')
param sharePointArchive sharePointArchiveConfigType

@description('Governance feature flags for HIPAA/HITRUST policy assignment and Microsoft Defender for Cloud plans.')
param governance governanceConfigType

// ---------------------------------------------------------------------------
// Naming context and resource group
// ---------------------------------------------------------------------------

var namingCtx = {
  workloadName: workloadName
  environmentName: environmentName
  regionCode: regionCode
  uniqueSuffix: uniqueString(subscription().subscriptionId, workloadName, environmentName, regionCode)
}

var commonTags = buildTags(tags)
var resourceGroupName = buildName('rg', namingCtx, false)

module rg 'br/public:avm/res/resources/resource-group:0.4.4' = {
  name: 'rg-${namingCtx.workloadName}-${regionCode}-deploy'
  scope: subscription()
  params: {
    name: resourceGroupName
    location: location
    tags: commonTags
  }
}

// ---------------------------------------------------------------------------
// Identities (created first: no other resource dependencies)
// ---------------------------------------------------------------------------

module identityCmk 'modules/managed-identity.bicep' = {
  name: 'id-cmk-deploy'
  scope: resourceGroup(resourceGroupName)
  dependsOn: [rg]
  params: {
    name: buildName('id-cmk', namingCtx, false)
    location: location
    tags: commonTags
  }
}

module identityFunc 'modules/managed-identity.bicep' = {
  name: 'id-func-deploy'
  scope: resourceGroup(resourceGroupName)
  dependsOn: [rg]
  params: {
    name: buildName('id-func', namingCtx, false)
    location: location
    tags: commonTags
  }
}

module identityLogic 'modules/managed-identity.bicep' = {
  name: 'id-logic-deploy'
  scope: resourceGroup(resourceGroupName)
  dependsOn: [rg]
  params: {
    name: buildName('id-logic', namingCtx, false)
    location: location
    tags: commonTags
  }
}

// ---------------------------------------------------------------------------
// Observability foundation (Log Analytics, action group)
// ---------------------------------------------------------------------------

module logAnalytics 'modules/log-analytics.bicep' = {
  name: 'log-deploy'
  scope: resourceGroup(resourceGroupName)
  dependsOn: [rg]
  params: {
    name: buildName('log', namingCtx, false)
    location: location
    tags: commonTags
    retention: logRetention
  }
}

module actionGroup 'modules/action-group.bicep' = {
  name: 'ag-deploy'
  scope: resourceGroup(resourceGroupName)
  dependsOn: [rg]
  params: {
    name: buildName('ag', namingCtx, false)
    tags: commonTags
    alerting: alerting
  }
}

// ---------------------------------------------------------------------------
// Network
// ---------------------------------------------------------------------------

var functionSubnetEgressRules = [
  {
    name: 'Deny-Lateral-Traversal-Outbound'
    properties: {
      access: 'Deny'
      direction: 'Outbound'
      priority: 100
      protocol: 'Tcp'
      sourceAddressPrefix: 'VirtualNetwork'
      sourcePortRange: '*'
      destinationAddressPrefix: 'VirtualNetwork'
      destinationPortRanges: [
        '22'
        '3389'
      ]
    }
  }
  {
    name: 'Allow-VNet-Outbound'
    properties: {
      access: 'Allow'
      direction: 'Outbound'
      priority: 110
      protocol: '*'
      sourceAddressPrefix: 'VirtualNetwork'
      sourcePortRange: '*'
      destinationAddressPrefix: 'VirtualNetwork'
      destinationPortRange: '*'
    }
  }
  {
    name: 'Allow-AAD-Outbound'
    properties: {
      access: 'Allow'
      direction: 'Outbound'
      priority: 120
      protocol: 'Tcp'
      sourceAddressPrefix: '*'
      sourcePortRange: '*'
      destinationAddressPrefix: 'AzureActiveDirectory'
      destinationPortRange: '443'
    }
  }
  {
    name: 'Allow-ARM-Outbound'
    properties: {
      access: 'Allow'
      direction: 'Outbound'
      priority: 130
      protocol: 'Tcp'
      sourceAddressPrefix: '*'
      sourcePortRange: '*'
      destinationAddressPrefix: 'AzureResourceManager'
      destinationPortRange: '443'
    }
  }
  {
    name: 'Allow-FunctionsExtensionBundles-Outbound'
    properties: {
      description: 'Allows Microsoft-hosted extension bundle downloads over TLS; cdn.functions.azure.com has no dedicated service tag.'
      access: 'Allow'
      direction: 'Outbound'
      priority: 140
      protocol: 'Tcp'
      sourceAddressPrefix: '*'
      sourcePortRange: '*'
      destinationAddressPrefix: 'AzureCloud'
      destinationPortRange: '443'
    }
  }
  {
    name: 'Deny-Internet-Outbound'
    properties: {
      access: 'Deny'
      direction: 'Outbound'
      priority: 4090
      protocol: '*'
      sourceAddressPrefix: '*'
      sourcePortRange: '*'
      destinationAddressPrefix: 'Internet'
      destinationPortRange: '*'
    }
  }
]

// The Logic Apps Standard integration subnet needs everything the Function
// subnet needs, plus two additional, deliberately narrow egress paths. With
// vnetRouteAllEnabled=true all workflow outbound traffic leaves through this
// subnet, so without these rules the Deny-Internet-Outbound rule silently
// breaks the Office 365 approval/reminder/escalation emails and the opt-in
// SharePoint archive.
//
//  * AzureConnectors  -- the Azure-hosted managed connector runtime that the
//    Office 365 Outlook managed connection is invoked through. This is a
//    first-class Azure service tag, so the rule stays scoped to Microsoft's
//    connector infrastructure rather than to the open Internet.
//
//  * Microsoft Graph  -- Microsoft publishes NO dedicated service tag for
//    graph.microsoft.com, and the AzureActiveDirectory tag covers only the
//    identity/login endpoints, not Graph itself. The narrowest service-tag
//    expression available is therefore AzureCloud (all Microsoft-owned Azure
//    public-cloud address space) on 443 only, and it is added ONLY when the
//    opt-in SharePoint archive feature is enabled -- the default deployment
//    keeps it closed. If your organization requires tighter egress than
//    AzureCloud, front this subnet with Azure Firewall and use an FQDN rule
//    for graph.microsoft.com, or maintain an explicit prefix list from the
//    published Azure IP Ranges and Service Tags file. Recorded as an open
//    egress decision in docs/ASSUMPTIONS.md.
var logicAppConnectorEgressRules = [
  {
    name: 'Allow-AzureConnectors-Outbound'
    properties: {
      access: 'Allow'
      direction: 'Outbound'
      priority: 150
      protocol: 'Tcp'
      sourceAddressPrefix: '*'
      sourcePortRange: '*'
      destinationAddressPrefix: 'AzureConnectors'
      destinationPortRange: '443'
    }
  }
]

var logicAppGraphEgressRules = sharePointArchive.enabled
  ? [
      {
        name: 'Allow-MicrosoftGraph-Outbound'
        properties: {
          access: 'Allow'
          direction: 'Outbound'
          priority: 160
          protocol: 'Tcp'
          sourceAddressPrefix: '*'
          sourcePortRange: '*'
          destinationAddressPrefix: 'AzureCloud'
          destinationPortRange: '443'
        }
      }
    ]
  : []

var logicAppSubnetEgressRules = concat(functionSubnetEgressRules, logicAppConnectorEgressRules, logicAppGraphEgressRules)

var privateEndpointSubnetRules = [
  {
    name: 'Deny-Lateral-Traversal-Inbound'
    properties: {
      access: 'Deny'
      direction: 'Inbound'
      priority: 100
      protocol: 'Tcp'
      sourceAddressPrefix: 'VirtualNetwork'
      sourcePortRange: '*'
      destinationAddressPrefix: 'VirtualNetwork'
      destinationPortRanges: [
        '22'
        '3389'
      ]
    }
  }
  {
    name: 'Allow-VNet-Inbound'
    properties: {
      access: 'Allow'
      direction: 'Inbound'
      priority: 110
      protocol: '*'
      sourceAddressPrefix: 'VirtualNetwork'
      sourcePortRange: '*'
      destinationAddressPrefix: 'VirtualNetwork'
      destinationPortRange: '*'
    }
  }
  {
    name: 'Deny-Internet-Inbound'
    properties: {
      access: 'Deny'
      direction: 'Inbound'
      priority: 4090
      protocol: '*'
      sourceAddressPrefix: 'Internet'
      sourcePortRange: '*'
      destinationAddressPrefix: '*'
      destinationPortRange: '*'
    }
  }
  {
    name: 'Deny-Lateral-Traversal-Outbound'
    properties: {
      access: 'Deny'
      direction: 'Outbound'
      priority: 4080
      protocol: 'Tcp'
      sourceAddressPrefix: 'VirtualNetwork'
      sourcePortRange: '*'
      destinationAddressPrefix: 'VirtualNetwork'
      destinationPortRanges: [
        '22'
        '3389'
      ]
    }
  }
]

module nsgFunc 'modules/nsg.bicep' = {
  name: 'nsg-func-deploy'
  scope: resourceGroup(resourceGroupName)
  params: {
    name: buildName('nsg-func', namingCtx, false)
    location: location
    tags: commonTags
    securityRules: functionSubnetEgressRules
    logAnalyticsWorkspaceResourceId: logAnalytics.outputs.resourceId
  }
}

module nsgLogic 'modules/nsg.bicep' = {
  name: 'nsg-logic-deploy'
  scope: resourceGroup(resourceGroupName)
  params: {
    name: buildName('nsg-logic', namingCtx, false)
    location: location
    tags: commonTags
    securityRules: logicAppSubnetEgressRules
    logAnalyticsWorkspaceResourceId: logAnalytics.outputs.resourceId
  }
}

module nsgPe 'modules/nsg.bicep' = {
  name: 'nsg-pe-deploy'
  scope: resourceGroup(resourceGroupName)
  params: {
    name: buildName('nsg-pe', namingCtx, false)
    location: location
    tags: commonTags
    securityRules: privateEndpointSubnetRules
    logAnalyticsWorkspaceResourceId: logAnalytics.outputs.resourceId
  }
}

var testVmSubnetRules = [
  {
    name: 'AllowRdpFromVirtualNetwork'
    properties: {
      description: 'Developer Bastion reaches the private test VM over the workload VNet; RDP is never exposed to the internet.'
      access: 'Allow'
      direction: 'Inbound'
      priority: 100
      protocol: 'Tcp'
      sourceAddressPrefix: 'VirtualNetwork'
      sourcePortRange: '*'
      destinationAddressPrefix: 'VirtualNetwork'
      destinationPortRange: '3389'
    }
  }
]

module nsgTestVm 'modules/nsg.bicep' = if (enableTestAccess) {
  name: 'nsg-test-vm-deploy'
  scope: resourceGroup(resourceGroupName)
  params: {
    name: buildName('nsg-test-vm', namingCtx, false)
    location: location
    tags: commonTags
    securityRules: testVmSubnetRules
    logAnalyticsWorkspaceResourceId: logAnalytics.outputs.resourceId
  }
}

module network 'modules/network.bicep' = {
  name: 'vnet-deploy'
  scope: resourceGroup(resourceGroupName)
  params: {
    name: buildName('vnet', namingCtx, false)
    location: location
    tags: commonTags
    networkConfig: networkConfig
    functionSubnetNsgResourceId: nsgFunc.outputs.resourceId
    logicAppSubnetNsgResourceId: nsgLogic.outputs.resourceId
    privateEndpointSubnetNsgResourceId: nsgPe.outputs.resourceId
    enableTestAccess: enableTestAccess
    testVmSubnetPrefix: testVmSubnetPrefix
    testVmSubnetNsgResourceId: enableTestAccess ? nsgTestVm!.outputs.resourceId : ''
    logAnalyticsWorkspaceResourceId: logAnalytics.outputs.resourceId
  }
}

module testAccess 'modules/test-access.bicep' = if (enableTestAccess) {
  name: 'test-access-deploy'
  scope: resourceGroup(resourceGroupName)
  params: {
    location: location
    tags: union(commonTags, {
      dataClassification: 'Synthetic test data only'
      workloadRole: 'workshop-test-access'
    })
    vmName: buildName('vm-test', namingCtx, false)
    bastionName: buildName('bas-dev', namingCtx, false)
    vmSize: testVmSize
    virtualNetworkResourceId: network.outputs.resourceId
    testVmSubnetResourceId: network.outputs.testVmSubnetResourceId
    testVmNsgResourceId: nsgTestVm!.outputs.resourceId
    adminUsername: testVmAdminUsername
    adminPassword: testVmAdminPassword
    administratorObjectId: testVmAdministratorObjectId
  }
}

var privateDnsZoneNames = [
  'privatelink.blob.${environment().suffixes.storage}'
  'privatelink.file.${environment().suffixes.storage}'
  'privatelink.queue.${environment().suffixes.storage}'
  'privatelink.table.${environment().suffixes.storage}'
  'privatelink.vaultcore.azure.net'
  'privatelink.cognitiveservices.azure.com'
  // Fixed Azure Private Link DNS zone name for Azure SQL (platform
  // constant, not a configurable connection endpoint).
  #disable-next-line no-hardcoded-env-urls
  'privatelink.database.windows.net'
  'privatelink.azurewebsites.net'
  'privatelink.monitor.azure.com'
  'privatelink.oms.opinsights.azure.com'
  'privatelink.ods.opinsights.azure.com'
  'privatelink.agentsvc.azure-automation.net'
]

module privateDns 'modules/private-dns.bicep' = {
  name: 'pdz-deploy'
  scope: resourceGroup(resourceGroupName)
  params: {
    zoneNames: privateDnsZoneNames
    tags: commonTags
    virtualNetworkResourceId: network.outputs.resourceId
  }
}

// Built here (rather than inside the private-dns module) because Bicep does
// not allow a variable's for-body to read module outputs; toObject() over an
// already-materialized output array has no such restriction.
var privateDnsZoneIdsByName = toObject(privateDns.outputs.zoneEntries, entry => entry.key, entry => entry.value)

// ---------------------------------------------------------------------------
// Key Vault
// ---------------------------------------------------------------------------

module keyVault 'modules/key-vault.bicep' = {
  name: 'kv-deploy'
  scope: resourceGroup(resourceGroupName)
  params: {
    name: buildAlphanumericName('kv', namingCtx, 24)
    location: location
    tags: commonTags
    softDeleteRetentionDays: keyVaultSoftDeleteRetentionDays
    privateEndpointSubnetResourceId: network.outputs.privateEndpointSubnetResourceId
    privateDnsZoneResourceId: privateDnsZoneIdsByName['privatelink.vaultcore.azure.net']
    logAnalyticsWorkspaceResourceId: logAnalytics.outputs.resourceId
    cmkIdentityPrincipalId: identityCmk.outputs.principalId
    functionIdentityPrincipalId: identityFunc.outputs.principalId
    deploymentPrincipalObjectId: deploymentArtifactsPublisherObjectId
    deploymentPrincipalType: deploymentArtifactsPublisherPrincipalType
  }
}

// ---------------------------------------------------------------------------
// Storage (PHI + runtime)
// ---------------------------------------------------------------------------

module storagePhi 'modules/storage-phi.bicep' = {
  name: 'st-phi-deploy'
  scope: resourceGroup(resourceGroupName)
  params: {
    name: buildAlphanumericName('stphi', namingCtx, 24)
    location: location
    tags: commonTags
    containerName: documentContainerName
    privateEndpointSubnetResourceId: network.outputs.privateEndpointSubnetResourceId
    blobPrivateDnsZoneResourceId: privateDnsZoneIdsByName['privatelink.blob.${environment().suffixes.storage}']
    logAnalyticsWorkspaceResourceId: logAnalytics.outputs.resourceId
    cmkIdentityResourceId: identityCmk.outputs.resourceId
    keyVaultResourceId: keyVault.outputs.resourceId
    cmkKeyName: 'cmk-storage'
    functionIdentityPrincipalId: identityFunc.outputs.principalId
    softDeleteRetentionDays: phiStorageSoftDeleteRetentionDays
    enableImmutabilityPolicy: enableImmutabilityPolicy
    immutabilityRetentionDays: immutabilityRetentionDays
  }
}

module storageRuntime 'modules/storage-runtime.bicep' = {
  name: 'st-runtime-deploy'
  scope: resourceGroup(resourceGroupName)
  params: {
    name: buildAlphanumericName('sthost', namingCtx, 24)
    location: location
    tags: commonTags
    functionContentShareName: functionContentShareName
    logicAppContentShareName: logicAppContentShareName
    privateEndpointSubnetResourceId: network.outputs.privateEndpointSubnetResourceId
    privateDnsZoneResourceIdsByService: {
      blob: privateDnsZoneIdsByName['privatelink.blob.${environment().suffixes.storage}']
      file: privateDnsZoneIdsByName['privatelink.file.${environment().suffixes.storage}']
      queue: privateDnsZoneIdsByName['privatelink.queue.${environment().suffixes.storage}']
      table: privateDnsZoneIdsByName['privatelink.table.${environment().suffixes.storage}']
    }
    logAnalyticsWorkspaceResourceId: logAnalytics.outputs.resourceId
    cmkIdentityResourceId: identityCmk.outputs.resourceId
    keyVaultResourceId: keyVault.outputs.resourceId
    cmkKeyName: 'cmk-storage'
    functionIdentityPrincipalId: identityFunc.outputs.principalId
    logicAppIdentityPrincipalId: identityLogic.outputs.principalId
    deploymentArtifactsContainerName: deploymentArtifactsContainerName
    deploymentArtifactsPublisherObjectId: deploymentArtifactsPublisherObjectId
    deploymentArtifactsPublisherPrincipalType: deploymentArtifactsPublisherPrincipalType
    softDeleteRetentionDays: phiStorageSoftDeleteRetentionDays
  }
}

// ---------------------------------------------------------------------------
// Application Insights + AMPLS
// ---------------------------------------------------------------------------

module appInsights 'modules/app-insights.bicep' = {
  name: 'appi-deploy'
  scope: resourceGroup(resourceGroupName)
  params: {
    name: buildName('appi', namingCtx, false)
    location: location
    tags: commonTags
    logAnalyticsWorkspaceResourceId: logAnalytics.outputs.resourceId
    functionIdentityPrincipalId: identityFunc.outputs.principalId
    logicAppIdentityPrincipalId: identityLogic.outputs.principalId
  }
}

module ampls 'modules/ampls.bicep' = {
  name: 'ampls-deploy'
  scope: resourceGroup(resourceGroupName)
  params: {
    name: buildName('ampls', namingCtx, false)
    location: location
    tags: commonTags
    logAnalyticsWorkspaceResourceId: logAnalytics.outputs.resourceId
    appInsightsResourceId: appInsights.outputs.resourceId
    privateEndpointSubnetResourceId: network.outputs.privateEndpointSubnetResourceId
    privateDnsZoneResourceIdsByZone: {
      monitor: privateDnsZoneIdsByName['privatelink.monitor.azure.com']
      oms: privateDnsZoneIdsByName['privatelink.oms.opinsights.azure.com']
      ods: privateDnsZoneIdsByName['privatelink.ods.opinsights.azure.com']
      agentsvc: privateDnsZoneIdsByName['privatelink.agentsvc.azure-automation.net']
    }
  }
}

// ---------------------------------------------------------------------------
// Document Intelligence
// ---------------------------------------------------------------------------

module documentIntelligence 'modules/document-intelligence.bicep' = {
  name: 'cog-di-deploy'
  scope: resourceGroup(resourceGroupName)
  params: {
    name: buildName('cog-di', namingCtx, false)
    location: location
    tags: commonTags
    customSubDomainName: buildAlphanumericName('di', namingCtx, 24)
    skuName: documentIntelligenceSkuName
    privateEndpointSubnetResourceId: network.outputs.privateEndpointSubnetResourceId
    privateDnsZoneResourceId: privateDnsZoneIdsByName['privatelink.cognitiveservices.azure.com']
    logAnalyticsWorkspaceResourceId: logAnalytics.outputs.resourceId
    cmkIdentityResourceId: identityCmk.outputs.resourceId
    keyVaultResourceId: keyVault.outputs.resourceId
    cmkKeyName: 'cmk-documentintelligence'
    enableCustomerManagedKey: enableDocumentIntelligenceCmk
    functionIdentityPrincipalId: identityFunc.outputs.principalId
    studioUserObjectId: documentIntelligenceStudioUserObjectId
  }
}

// ---------------------------------------------------------------------------
// SQL
// ---------------------------------------------------------------------------

module sql 'modules/sql.bicep' = {
  name: 'sql-deploy'
  scope: resourceGroup(resourceGroupName)
  params: {
    serverName: buildAlphanumericName('sql', namingCtx, 63)
    databaseName: sqlDatabaseName
    location: location
    tags: commonTags
    tenantId: subscription().tenantId
    entraGroups: entraGroups
    databaseConfig: sqlDatabaseConfig
    privateEndpointSubnetResourceId: network.outputs.privateEndpointSubnetResourceId
    #disable-next-line no-hardcoded-env-urls
    privateDnsZoneResourceId: privateDnsZoneIdsByName['privatelink.database.windows.net']
    logAnalyticsWorkspaceResourceId: logAnalytics.outputs.resourceId
    cmkIdentityResourceId: identityCmk.outputs.resourceId
    keyVaultResourceId: keyVault.outputs.resourceId
    cmkKeyName: 'cmk-sql-tde'
    vulnerabilityAssessmentStorageAccountResourceId: storageRuntime.outputs.resourceId
    maintenanceConfigurationId: subscriptionResourceId('Microsoft.Maintenance/publicMaintenanceConfigurations', maintenanceConfigurationName)
  }
}

// ---------------------------------------------------------------------------
// Function App
// ---------------------------------------------------------------------------

// Stable, versionless location of the Function deployment package inside the
// CI overrides functionPackageBlobName with a SHA-256-addressed blob path so
// infrastructure redeployments preserve the exact immutable package version.
var functionPackageUrl = '${storageRuntime.outputs.primaryBlobEndpoint}${deploymentArtifactsContainerName}/${functionPackageBlobName}'

module functionApp 'modules/function-app.bicep' = {
  name: 'func-deploy'
  scope: resourceGroup(resourceGroupName)
  params: {
    planName: buildName('asp-funcpy', namingCtx, false)
    siteName: buildName('funcpy', namingCtx, true)
    location: location
    tags: commonTags
    skuName: functionAppSkuName
    minimumInstanceCount: functionMinimumInstanceCount
    maximumElasticInstanceCount: functionMaximumElasticInstanceCount
    functionSubnetResourceId: network.outputs.functionSubnetResourceId
    privateEndpointSubnetResourceId: network.outputs.privateEndpointSubnetResourceId
    privateDnsZoneResourceId: privateDnsZoneIdsByName['privatelink.azurewebsites.net']
    logAnalyticsWorkspaceResourceId: logAnalytics.outputs.resourceId
    hostStorageAccountName: storageRuntime.outputs.name
    hostStorageAccountResourceId: storageRuntime.outputs.resourceId
    contentShareName: functionContentShareName
    functionIdentityResourceId: identityFunc.outputs.resourceId
    functionIdentityClientId: identityFunc.outputs.clientId
    packagePullIdentityResourceId: identityFunc.outputs.resourceId
    runFromPackageUrl: functionPackageUrl
    appInsightsResourceId: appInsights.outputs.resourceId
    phiStorageBlobServiceUri: storagePhi.outputs.primaryBlobEndpoint
    phiContainerName: documentContainerName
    phiIncomingPrefix: functionIncomingPrefix
    keyVaultUri: keyVault.outputs.uri
    businessRulesCallbackSecretName: businessRulesCallbackSecretName
    documentIntelligenceEndpoint: documentIntelligence.outputs.endpoint
    documentIntelligenceModelId: documentIntelligenceExtractionModelId
    documentClassifierModelId: documentIntelligenceClassifierModelId
    sqlServerFqdn: sql.outputs.serverFqdn
    sqlDatabaseName: sql.outputs.databaseName
    confidenceThreshold: businessRules.confidenceThreshold
    highRiskDocumentTypes: businessRules.highRiskDocumentTypes
    requiredFields: businessRules.requiredFields
    sasLinkExpiryHours: sasLinkExpiryHours
  }
}

// ---------------------------------------------------------------------------
// Logic App (Standard)
// ---------------------------------------------------------------------------

// ---------------------------------------------------------------------------
// Office 365 Outlook API connection (human-approval-workflow)
// ---------------------------------------------------------------------------

module apiConnections 'modules/api-connections.bicep' = {
  name: 'con-deploy'
  scope: resourceGroup(resourceGroupName)
  params: {
    location: location
    tags: commonTags
    // V1 -> V2 is not an in-place update for Microsoft.Web/connections, so
    // use a versioned name to create the Standard-workflow-compatible resource.
    office365ConnectionName: buildName('con-o365-v2', namingCtx, false)
    office365ConnectionDisplayName: 'Document Intake AI - reviewer approval mailbox'
  }
}

// ---------------------------------------------------------------------------
// Logic App (Standard)
// ---------------------------------------------------------------------------

module logicApp 'modules/logic-app.bicep' = {
  name: 'logic-deploy'
  scope: resourceGroup(resourceGroupName)
  params: {
    planName: buildName('asp-logic', namingCtx, false)
    siteName: buildName('logic-v2', namingCtx, true)
    location: location
    tags: commonTags
    workerCount: logicAppWorkerCount
    logicAppSubnetResourceId: network.outputs.logicAppSubnetResourceId
    privateEndpointSubnetResourceId: network.outputs.privateEndpointSubnetResourceId
    privateDnsZoneResourceId: privateDnsZoneIdsByName['privatelink.azurewebsites.net']
    logAnalyticsWorkspaceResourceId: logAnalytics.outputs.resourceId
    hostStorageAccountName: storageRuntime.outputs.name
    hostStorageAccountResourceId: storageRuntime.outputs.resourceId
    contentShareName: logicAppContentShareName
    logicAppIdentityResourceId: identityLogic.outputs.resourceId
    logicAppIdentityClientId: identityLogic.outputs.clientId
    sasLinkExpiryHours: sasLinkExpiryHours
    appInsightsResourceId: appInsights.outputs.resourceId
    confidenceThreshold: businessRules.confidenceThreshold
    highRiskDocumentTypes: businessRules.highRiskDocumentTypes
    requiredFields: businessRules.requiredFields
    reviewReminderAfterHours: businessRules.reviewReminderAfterHours
    reviewEscalationAfterHours: businessRules.reviewEscalationAfterHours
    sqlServerFqdn: sql.outputs.serverFqdn
    sqlDatabaseName: sql.outputs.databaseName
    phiStorageBlobServiceUri: storagePhi.outputs.primaryBlobEndpoint
    phiContainerName: documentContainerName
    reviewerGroupEmail: entraGroups.reviewerGroupEmail
    supervisorGroupEmail: entraGroups.supervisorGroupEmail
    office365ConnectionResourceId: apiConnections.outputs.office365ConnectionResourceId
    office365ConnectionRuntimeUrl: apiConnections.outputs.office365ConnectionRuntimeUrl
    enableSharePointArchive: sharePointArchive.enabled
    sharePointSiteId: sharePointArchive.siteId
    sharePointDriveId: sharePointArchive.driveId
    sharePointFolderPath: sharePointArchive.folderPath
  }
}

// Post-hoc role assignments for the Logic App's SYSTEM-ASSIGNED identity.
// These must come after logicApp because that identity's principal ID does
// not exist until the Logic App site is deployed.
var storageBlobDataContributorRoleId = 'ba92f5b4-2d11-453d-a403-e96b0029c9fe'

module logicAppBlobRoleAssignment 'modules/storage-container-role-assignment.bicep' = {
  name: 'ra-logic-blob-deploy'
  scope: resourceGroup(resourceGroupName)
  params: {
    storageAccountName: storagePhi.outputs.name
    containerName: documentContainerName
    principalId: logicApp.outputs.systemAssignedPrincipalId
    roleDefinitionId: storageBlobDataContributorRoleId
    roleDescription: 'Logic App (system-assigned identity, required by the Standard built-in Azure Blob connector): move approved blobs incoming -> processed, container-scoped only.'
  }
}

module testVmBlobRoleAssignment 'modules/storage-container-role-assignment.bicep' = if (enableTestAccess) {
  name: 'ra-test-vm-blob-deploy'
  scope: resourceGroup(resourceGroupName)
  params: {
    storageAccountName: storagePhi.outputs.name
    containerName: documentContainerName
    principalId: testAccess!.outputs.vmPrincipalId
    roleDefinitionId: storageBlobDataContributorRoleId
    roleDescription: 'Workshop test VM managed identity: upload synthetic intake fixtures to the documents container; never use for real PHI.'
  }
}

// Permission for the Logic App's system-assigned identity to USE the Office
// 365 managed API connection at runtime. Interactive OAuth consent on the
// connection is a separate, manual step (see modules/api-connections.bicep);
// without BOTH, the approval/reminder/escalation mail actions fail.
module office365ConnectionAccessPolicy 'modules/connection-access-policy.json' = {
  name: 'con-o365-accesspolicy-deploy'
  scope: resourceGroup(resourceGroupName)
  params: {
    connectionName: apiConnections.outputs.office365ConnectionName
    location: location
    tenantId: subscription().tenantId
    principalObjectId: logicApp.outputs.systemAssignedPrincipalId
  }
}

// ---------------------------------------------------------------------------
// Alerts + workbook
// ---------------------------------------------------------------------------

module alerts 'modules/alerts.bicep' = {
  name: 'alerts-deploy'
  scope: resourceGroup(resourceGroupName)
  params: {
    tags: commonTags
    location: location
    actionGroupResourceId: actionGroup.outputs.resourceId
    runtimeStorageAccountResourceId: storageRuntime.outputs.resourceId
    documentIntelligenceResourceId: documentIntelligence.outputs.resourceId
    logAnalyticsWorkspaceResourceId: logAnalytics.outputs.resourceId
    criticalSeverity: criticalAlertSeverity
    slaSeverity: slaAlertSeverity
    keyVaultAnomalyThreshold: keyVaultAnomalyThreshold
  }
}

module workbook 'modules/workbook.bicep' = {
  name: 'workbook-deploy'
  scope: resourceGroup(resourceGroupName)
  params: {
    displayName: 'Document Intake AI - Operations'
    location: location
    tags: commonTags
    logAnalyticsWorkspaceResourceId: logAnalytics.outputs.resourceId
    workbookId: guid(resourceGroupName, 'workbook-intake-ops')
  }
}

// ---------------------------------------------------------------------------
// Governance (feature-flagged)
// ---------------------------------------------------------------------------

module governancePolicy 'modules/governance-policy.bicep' = {
  name: 'policy-${regionCode}-deploy'
  scope: subscription()
  params: {
    location: location
    enableHipaaHitrustPolicy: governance.enableHipaaHitrustPolicy
    policyEnforcementMode: governance.policyEnforcementMode
  }
}

module defender 'modules/defender.bicep' = {
  name: 'defender-${regionCode}-deploy'
  scope: subscription()
  params: {
    enableDefenderForCloud: governance.enableDefenderForCloud
    defenderPlanNames: governance.defenderPlanNames
  }
}

// ---------------------------------------------------------------------------
// Outputs (no secrets)
// ---------------------------------------------------------------------------

@description('Name of the deployed resource group.')
output resourceGroupName string = resourceGroupName

@description('Resource ID of the VNet.')
output virtualNetworkResourceId string = network.outputs.resourceId

@description('Resource ID of the PHI storage account.')
output phiStorageAccountResourceId string = storagePhi.outputs.resourceId

@description('Private blob endpoint of the PHI storage account.')
output phiStorageBlobEndpoint string = storagePhi.outputs.primaryBlobEndpoint

@description('Resource ID of the Document Intelligence account.')
output documentIntelligenceResourceId string = documentIntelligence.outputs.resourceId

@description('Resource ID of the Function App.')
output functionAppResourceId string = functionApp.outputs.resourceId

@description('Name of the Function App, used by the code-deploy job in .github/workflows/deploy.yml.')
output functionAppName string = functionApp.outputs.name

@description('Default (private) hostname of the Function App.')
output functionAppDefaultHostname string = functionApp.outputs.defaultHostname

@description('Resource ID of the Logic App.')
output logicAppResourceId string = logicApp.outputs.resourceId

@description('Name of the Logic App, used by the code-deploy job in .github/workflows/deploy.yml.')
output logicAppName string = logicApp.outputs.name

@description('Name of the runtime storage account that hosts the private deployment-artifacts container.')
output deploymentArtifactsStorageAccountName string = storageRuntime.outputs.name

@description('Name of the private deployment-artifacts container application packages are published to.')
output deploymentArtifactsContainerName string = storageRuntime.outputs.deploymentArtifactsContainerName

@description('Exact immutable blob URL the Function App run-from-package setting points at.')
output functionPackageBlobUrl string = functionPackageUrl

@description('False when the Document Intelligence account is still using Microsoft-managed keys because the CMK second pass has not been run -- see infra/modules/document-intelligence.bicep.')
output documentIntelligenceCustomerManagedKeyApplied bool = documentIntelligence.outputs.customerManagedKeyApplied

@description('Default (private) hostname of the Logic App.')
output logicAppDefaultHostname string = logicApp.outputs.defaultHostname

@description('Resource ID of the SQL logical server.')
output sqlServerResourceId string = sql.outputs.serverResourceId

@description('Fully-qualified DNS name of the SQL logical server.')
output sqlServerFqdn string = sql.outputs.serverFqdn

@description('Resource ID of the Key Vault.')
output keyVaultResourceId string = keyVault.outputs.resourceId

@description('Key Vault name used by the code-deploy job to rotate the signed business-rules workflow callback secret.')
output keyVaultName string = keyVault.outputs.name

@description('Versionless secret name that stores the signed business-rules workflow callback URL.')
output businessRulesCallbackSecret string = businessRulesCallbackSecretName

@description('Resource ID of the Office 365 Outlook API connection. Requires manual, interactive OAuth consent post-deploy -- see docs/runbook.md.')
output office365ConnectionResourceId string = apiConnections.outputs.office365ConnectionResourceId

@description('Resource ID of the Log Analytics workspace.')
output logAnalyticsWorkspaceResourceId string = logAnalytics.outputs.resourceId

@description('Resource ID of the operations workbook.')
output workbookResourceId string = workbook.outputs.resourceId

@description('Name of the optional workshop test VM, or empty when disabled.')
output testVmName string = enableTestAccess ? testAccess!.outputs.vmName : ''

@description('Name of the optional Developer Bastion resource, or empty when disabled.')
output testBastionName string = enableTestAccess ? testAccess!.outputs.bastionName : ''

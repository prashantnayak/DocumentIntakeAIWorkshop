// Thin wrapper over avm/res/storage/storage-account for the shared
// Functions + Logic Apps runtime/host storage account. This account is
// intentionally separate from PHI storage (storage-phi.bicep) and never
// stores document content.
//
// NARROW, DOCUMENTED EXCEPTION: Azure Functions Elastic Premium and Logic
// Apps Standard both require an Azure Files content share
// (WEBSITE_CONTENTAZUREFILECONNECTIONSTRING/WEBSITE_CONTENTSHARE) for
// scale-controller coordination. Logic Apps Standard's workflow-state
// provider also requires a classic AzureWebJobsStorage connection string and
// fails when only identity-based host settings are supplied. Therefore, and
// ONLY for this isolated non-PHI runtime storage account, allowSharedKeyAccess
// is left enabled. The Python Function continues to use managed identity for
// AzureWebJobsStorage, and all application data connections remain
// identity-based. Account keys are never written to source control or exposed
// as outputs; consuming resources resolve them at deployment time.
metadata name = 'storage-runtime'
metadata description = 'Opinionated wrapper over AVM storage-account for Functions + Logic Apps host storage, with a documented Shared Key exception for platform-required Logic App host storage and content shares.'

@description('Storage account resource name (already validated to be <=24 lowercase alphanumeric characters by the caller).')
param name string

@description('Azure region for the storage account.')
param location string

@description('Common resource tags.')
param tags object

@description('Name of the Azure Files content share used by the Function App.')
param functionContentShareName string

@description('Name of the Azure Files content share used by the Logic App.')
param logicAppContentShareName string

@description('Resource ID of the private-endpoint subnet.')
param privateEndpointSubnetResourceId string

@description('Resource IDs of the blob/file/queue/table private DNS zones, keyed by service name.')
param privateDnsZoneResourceIdsByService object

@description('Resource ID of the Log Analytics workspace for diagnostics.')
param logAnalyticsWorkspaceResourceId string

@description('Resource ID of the shared CMK user-assigned identity.')
param cmkIdentityResourceId string

@description('Resource ID of the Key Vault holding the storage customer-managed key.')
param keyVaultResourceId string

@description('Name of the customer-managed key used to encrypt this storage account.')
param cmkKeyName string

@description('Principal ID of the Function App user-assigned identity, granted the data-plane roles required for identity-based AzureWebJobsStorage access.')
param functionIdentityPrincipalId string

@description('Principal ID of the Logic App USER-ASSIGNED identity, granted the data-plane roles required for identity-based AzureWebJobsStorage access. This is distinct from the Logic App system-assigned identity used by the workflow-level built-in Blob connector.')
param logicAppIdentityPrincipalId string

@description('Name of the private container holding SHA-256-addressed application deployment packages. Never holds PHI -- only build artifacts.')
param deploymentArtifactsContainerName string

@description('Object ID of the CI/CD deployment principal that publishes application packages into the deployment-artifacts container. Leave empty to skip the grant (for example when packages are published manually by an already-privileged operator).')
param deploymentArtifactsPublisherObjectId string

@allowed([
  'ServicePrincipal'
  'User'
  'Group'
])
@description('Microsoft Entra principal type of the deployment package publisher.')
param deploymentArtifactsPublisherPrincipalType string = 'ServicePrincipal'

@minValue(1)
@maxValue(365)
@description('Blob and container soft-delete retention in days for this runtime account. Shorter than the PHI account: nothing here is PHI, it only guards deployment packages and host state against an accidental delete.')
param softDeleteRetentionDays int

var storageBlobDataOwnerRoleId = 'b7e6dc6d-f1e8-4753-8033-0f276bb0955b'
var storageQueueDataContributorRoleId = '974c5e8b-45b9-4653-ba55-5f855dd0fb88'
var storageTableDataContributorRoleId = '0a9a7e1f-b9d0-4cc4-a60d-0319b160aaa3'
var storageBlobDataReaderRoleId = '2a2b9908-6ea1-4ae2-8e65-a410df84e7d1'
var storageBlobDataContributorRoleId = 'ba92f5b4-2d11-453d-a403-e96b0029c9fe'

// Read-only pull for the two app hosts (Functions' run-from-package fetch),
// plus write access for the CI/CD publisher when its object ID is supplied.
var deploymentArtifactsRoleAssignments = concat(
  [
    {
      principalId: functionIdentityPrincipalId
      roleDefinitionIdOrName: storageBlobDataReaderRoleId
      principalType: 'ServicePrincipal'
      description: 'Function App run-from-package: pulls its own deployment package from this container using managed identity.'
    }
  ],
  empty(deploymentArtifactsPublisherObjectId)
    ? []
    : [
        {
          principalId: deploymentArtifactsPublisherObjectId
          roleDefinitionIdOrName: storageBlobDataContributorRoleId
          principalType: deploymentArtifactsPublisherPrincipalType
          description: 'CI/CD deployment principal: publishes application deployment packages into this container only.'
        }
      ]
)

module storageAccount 'br/public:avm/res/storage/storage-account:0.33.0' = {
  name: take('st-${name}-deploy', 64)
  params: {
    name: name
    location: location
    tags: tags
    kind: 'StorageV2'
    skuName: 'Standard_ZRS'
    accessTier: 'Hot'
    // Documented, isolated exception -- see file header comment.
    allowSharedKeyAccess: true
    allowBlobPublicAccess: false
    allowCrossTenantReplication: false
    publicNetworkAccess: 'Disabled'
    minimumTlsVersion: 'TLS1_2'
    supportsHttpsTrafficOnly: true
    networkAcls: {
      defaultAction: 'Deny'
      bypass: 'AzureServices'
    }
    managedIdentities: {
      userAssignedResourceIds: [
        cmkIdentityResourceId
      ]
    }
    customerManagedKey: {
      keyVaultResourceId: keyVaultResourceId
      keyName: cmkKeyName
      userAssignedIdentityResourceId: cmkIdentityResourceId
    }
    roleAssignments: [
      {
        principalId: functionIdentityPrincipalId
        roleDefinitionIdOrName: storageBlobDataOwnerRoleId
        principalType: 'ServicePrincipal'
        description: 'Identity-based AzureWebJobsStorage: blob trigger/lease state for the Function host.'
      }
      {
        principalId: functionIdentityPrincipalId
        roleDefinitionIdOrName: storageQueueDataContributorRoleId
        principalType: 'ServicePrincipal'
        description: 'Identity-based AzureWebJobsStorage: internal queue state for the Function host.'
      }
      {
        principalId: functionIdentityPrincipalId
        roleDefinitionIdOrName: storageTableDataContributorRoleId
        principalType: 'ServicePrincipal'
        description: 'Identity-based AzureWebJobsStorage: internal table state for the Function host.'
      }
      {
        principalId: logicAppIdentityPrincipalId
        roleDefinitionIdOrName: storageBlobDataOwnerRoleId
        principalType: 'ServicePrincipal'
        description: 'Identity-based AzureWebJobsStorage: blob state for the Logic App host.'
      }
      {
        principalId: logicAppIdentityPrincipalId
        roleDefinitionIdOrName: storageQueueDataContributorRoleId
        principalType: 'ServicePrincipal'
        description: 'Identity-based AzureWebJobsStorage: internal queue state for the Logic App host.'
      }
      {
        principalId: logicAppIdentityPrincipalId
        roleDefinitionIdOrName: storageTableDataContributorRoleId
        principalType: 'ServicePrincipal'
        description: 'Identity-based AzureWebJobsStorage: internal table state for the Logic App host.'
      }
    ]
    fileServices: {
      shares: [
        {
          name: functionContentShareName
          shareQuota: 1024
        }
        {
          name: logicAppContentShareName
          shareQuota: 1024
        }
      ]
    }
    blobServices: {
      // Container-level soft delete protects the deployment-artifacts
      // container (and therefore rollback history) from an accidental delete.
      // This account holds no PHI, so the retention window is short.
      deleteRetentionPolicyEnabled: true
      deleteRetentionPolicyDays: softDeleteRetentionDays
      containerDeleteRetentionPolicyEnabled: true
      containerDeleteRetentionPolicyDays: softDeleteRetentionDays
      containers: [
        {
          name: deploymentArtifactsContainerName
          publicAccess: 'None'
          roleAssignments: deploymentArtifactsRoleAssignments
        }
        {
          name: 'vulnerability-assessment'
          publicAccess: 'None'
        }
      ]
    }
    privateEndpoints: [
      {
        name: 'pe-${name}-blob'
        service: 'blob'
        subnetResourceId: privateEndpointSubnetResourceId
        privateDnsZoneGroup: {
          privateDnsZoneGroupConfigs: [
            { privateDnsZoneResourceId: privateDnsZoneResourceIdsByService.blob }
          ]
        }
      }
      {
        name: 'pe-${name}-file'
        service: 'file'
        subnetResourceId: privateEndpointSubnetResourceId
        privateDnsZoneGroup: {
          privateDnsZoneGroupConfigs: [
            { privateDnsZoneResourceId: privateDnsZoneResourceIdsByService.file }
          ]
        }
      }
      {
        name: 'pe-${name}-queue'
        service: 'queue'
        subnetResourceId: privateEndpointSubnetResourceId
        privateDnsZoneGroup: {
          privateDnsZoneGroupConfigs: [
            { privateDnsZoneResourceId: privateDnsZoneResourceIdsByService.queue }
          ]
        }
      }
      {
        name: 'pe-${name}-table'
        service: 'table'
        subnetResourceId: privateEndpointSubnetResourceId
        privateDnsZoneGroup: {
          privateDnsZoneGroupConfigs: [
            { privateDnsZoneResourceId: privateDnsZoneResourceIdsByService.table }
          ]
        }
      }
    ]
    diagnosticSettings: [
      {
        name: 'diag-${name}'
        workspaceResourceId: logAnalyticsWorkspaceResourceId
        metricCategories: [
          { category: 'Transaction' }
        ]
      }
    ]
  }
}

resource runtimeStorageAccount 'Microsoft.Storage/storageAccounts@2025-01-01' existing = {
  name: name
}

resource defaultQueueService 'Microsoft.Storage/storageAccounts/queueServices@2025-01-01' existing = {
  parent: runtimeStorageAccount
  name: 'default'
}

#disable-next-line use-recent-api-versions
resource queueDiagnostics 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = {
  name: 'diag-${name}-queue'
  scope: defaultQueueService
  properties: {
    workspaceId: logAnalyticsWorkspaceResourceId
    logAnalyticsDestinationType: 'Dedicated'
    logs: [
      {
        category: 'StorageWrite'
        enabled: true
      }
    ]
    metrics: [
      {
        category: 'Transaction'
        enabled: true
      }
    ]
  }
  dependsOn: [
    storageAccount
  ]
}

@description('Resource ID of the runtime storage account.')
output resourceId string = storageAccount.outputs.resourceId

@description('Name of the runtime storage account.')
output name string = storageAccount.outputs.name

@description('Primary blob endpoint (private) of the runtime storage account.')
output primaryBlobEndpoint string = storageAccount.outputs.primaryBlobEndpoint

@description('Name of the private deployment-artifacts container.')
output deploymentArtifactsContainerName string = deploymentArtifactsContainerName

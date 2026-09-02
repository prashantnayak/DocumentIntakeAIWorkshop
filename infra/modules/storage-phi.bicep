// Thin wrapper over avm/res/storage/storage-account for the PHI document
// landing zone. Single 'documents' container; incoming/processed/failed are
// virtual (blob name prefixes), not separate containers, per the confirmed
// reconciliation in docs/ASSUMPTIONS.md.
//
// Hard PHI controls: allowSharedKeyAccess=false (Entra ID only; only User
// Delegation SAS is possible), publicNetworkAccess Disabled, customer-managed
// key, blob versioning + soft delete, optional time-based immutability.
metadata name = 'storage-phi'
metadata description = 'Opinionated wrapper over AVM storage-account for PHI blob storage: keyless, private, CMK-encrypted, versioned.'

@description('Storage account resource name (already validated to be <=24 lowercase alphanumeric characters by the caller).')
param name string

@description('Azure region for the storage account.')
param location string

@description('Common resource tags.')
param tags object

@description('Name of the single PHI blob container.')
param containerName string

@description('Resource ID of the private-endpoint subnet.')
param privateEndpointSubnetResourceId string

@description('Resource ID of the privatelink.blob.core.windows.net private DNS zone.')
param blobPrivateDnsZoneResourceId string

@description('Resource ID of the Log Analytics workspace for diagnostics.')
param logAnalyticsWorkspaceResourceId string

@description('Resource ID of the shared CMK user-assigned identity.')
param cmkIdentityResourceId string

@description('Resource ID of the Key Vault holding the storage customer-managed key.')
param keyVaultResourceId string

@description('Name of the customer-managed key used to encrypt this storage account.')
param cmkKeyName string

@description('Principal ID of the Function App user-assigned identity, granted Storage Blob Data Contributor + Storage Blob Delegator scoped to this storage account so it can read/write/move blobs and mint user-delegation SAS links.')
param functionIdentityPrincipalId string

// NOTE: the Logic App's Storage Blob Data Contributor grant on this
// container is deliberately NOT parameterized here. The Standard built-in
// Azure Blob Storage connector only supports the Logic App's SYSTEM-ASSIGNED
// identity, whose principal ID does not exist until the Logic App site
// itself is deployed -- which in turn needs this storage account's blob
// endpoint as an app setting. Granting that role here would create a
// circular dependency. main.bicep breaks the cycle by deploying the Logic
// App first and then granting this role via
// modules/storage-container-role-assignment.bicep once the principal ID is
// known. See docs/architecture.md "Deployment ordering" section.

@minValue(1)
@maxValue(365)
@description('Blob and container soft-delete retention in days.')
param softDeleteRetentionDays int

@description('Feature flag for time-based immutability (WORM) on the documents container. Left disabled by default in the dev/workshop environment because immutability would block synthetic-fixture cleanup; enable and set immutabilityRetentionDays before handling real PHI.')
param enableImmutabilityPolicy bool

@minValue(1)
@maxValue(146000)
@description('Immutability retention period in days, used only when enableImmutabilityPolicy is true.')
param immutabilityRetentionDays int

var storageBlobDataOwnerRoleId = 'b7e6dc6d-f1e8-4753-8033-0f276bb0955b'
var storageBlobDelegatorRoleId = 'db58b8e5-c6ad-4a2a-8342-4190687cbf4a'

module storageAccount 'br/public:avm/res/storage/storage-account:0.33.0' = {
  name: take('st-${name}-deploy', 64)
  params: {
    name: name
    location: location
    tags: tags
    kind: 'StorageV2'
    skuName: 'Standard_ZRS'
    accessTier: 'Hot'
    allowSharedKeyAccess: false
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
        roleDefinitionIdOrName: storageBlobDelegatorRoleId
        principalType: 'ServicePrincipal'
        description: 'Allows the Function identity to mint short-lived user delegation SAS links for reviewer emails (Shared Key is disabled on this account).'
      }
    ]
    blobServices: {
      deleteRetentionPolicyEnabled: true
      deleteRetentionPolicyDays: softDeleteRetentionDays
      containerDeleteRetentionPolicyEnabled: true
      containerDeleteRetentionPolicyDays: softDeleteRetentionDays
      isVersioningEnabled: true
      changeFeedEnabled: true
      lastAccessTimeTrackingPolicyEnabled: true
      containers: [
        {
          name: containerName
          publicAccess: 'None'
          denyEncryptionScopeOverride: false
          defaultEncryptionScope: '$account-encryption-key'
          immutabilityPolicy: enableImmutabilityPolicy
            ? {
                immutabilityPeriodSinceCreationInDays: immutabilityRetentionDays
              }
            : null
          roleAssignments: [
            {
              principalId: functionIdentityPrincipalId
              roleDefinitionIdOrName: storageBlobDataOwnerRoleId
              principalType: 'ServicePrincipal'
              description: 'Function App: polling Blob-trigger data role plus exact-version processing, container-scoped only.'
            }
          ]
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
            {
              privateDnsZoneResourceId: blobPrivateDnsZoneResourceId
            }
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

@description('Resource ID of the PHI storage account.')
output resourceId string = storageAccount.outputs.resourceId

@description('Name of the PHI storage account.')
output name string = storageAccount.outputs.name

@description('Primary blob endpoint (private).')
output primaryBlobEndpoint string = storageAccount.outputs.primaryBlobEndpoint

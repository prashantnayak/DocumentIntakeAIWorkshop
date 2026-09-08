// Thin wrapper over avm/res/key-vault/vault.
// Premium (HSM-backed) SKU, RBAC authorization, purge protection, private
// endpoint, and customer-managed keys (storage, document
// intelligence, SQL TDE) each with an automatic rotation policy.
metadata name = 'key-vault'
metadata description = 'Opinionated wrapper over AVM key-vault/vault: RBAC-only, purge-protected, private, with rotation-enabled CMKs.'

@description('Key Vault resource name.')
param name string

@description('Azure region for the Key Vault.')
param location string

@description('Common resource tags.')
param tags object

@minValue(7)
@maxValue(90)
@description('Soft-delete retention in days.')
param softDeleteRetentionDays int

@description('Resource ID of the private-endpoint subnet.')
param privateEndpointSubnetResourceId string

@description('Resource ID of the privatelink.vaultcore.azure.net private DNS zone.')
param privateDnsZoneResourceId string

@description('Resource ID of the Log Analytics workspace for diagnostics.')
param logAnalyticsWorkspaceResourceId string

@description('Principal ID of the CMK managed identity, granted Key Vault Crypto Service Encryption User so dependent services can wrap/unwrap with the keys below.')
param cmkIdentityPrincipalId string

@description('Function App user-assigned identity that resolves the signed Logic App callback URL through a Key Vault app-setting reference.')
param functionIdentityPrincipalId string

@description('Optional CI/CD principal allowed to rotate the Logic App callback secret during code deployment.')
param deploymentPrincipalObjectId string = ''

@allowed([
  'ServicePrincipal'
  'User'
  'Group'
])
@description('Microsoft Entra principal type of the deployment principal.')
param deploymentPrincipalType string = 'ServicePrincipal'

@description('Names of the customer-managed keys to create: storage, document intelligence, and SQL TDE.')
param cmkKeyNames object = {
  storage: 'cmk-storage'
  documentIntelligence: 'cmk-documentintelligence'
  sqlTde: 'cmk-sql-tde'
}

// Key Vault Crypto Service Encryption User - lets a resource provider's
// managed identity wrap/unwrap data encryption keys without other key
// management permissions.
var keyVaultCryptoServiceEncryptionUserRoleId = 'e147488a-f6f5-4113-8e2d-b22465e65bf6'
var keyVaultSecretsUserRoleId = '4633458b-17de-408a-b874-0445c86b69e6'
var keyVaultSecretsOfficerRoleId = 'b86a8fe4-44ce-4948-aee5-eccb2c155cd7'

var vaultRoleAssignments = concat(
  [
    {
      principalId: cmkIdentityPrincipalId
      roleDefinitionIdOrName: keyVaultCryptoServiceEncryptionUserRoleId
      principalType: 'ServicePrincipal'
      description: 'Allows the shared CMK identity to wrap/unwrap keys on behalf of Storage, Document Intelligence, and SQL.'
    }
    {
      principalId: functionIdentityPrincipalId
      roleDefinitionIdOrName: keyVaultSecretsUserRoleId
      principalType: 'ServicePrincipal'
      description: 'Allows the Python Function to resolve the signed business-rules workflow callback from a Key Vault reference.'
    }
  ],
  empty(deploymentPrincipalObjectId)
    ? []
    : [
        {
          principalId: deploymentPrincipalObjectId
          roleDefinitionIdOrName: keyVaultSecretsOfficerRoleId
          principalType: deploymentPrincipalType
          description: 'Allows the deployment workflow to rotate the Logic App callback URL secret after publishing workflow definitions.'
        }
      ]
)

var rotationPolicy = {
  attributes: {
    expiryTime: 'P1Y'
  }
  lifetimeActions: [
    {
      trigger: {
        timeBeforeExpiry: 'P30D'
      }
      action: {
        type: 'rotate'
      }
    }
    {
      trigger: {
        timeBeforeExpiry: 'P60D'
      }
      action: {
        type: 'notify'
      }
    }
  ]
}

module keyVault 'br/public:avm/res/key-vault/vault:0.14.0' = {
  name: take('kv-${name}-deploy', 64)
  params: {
    name: name
    location: location
    tags: tags
    sku: 'premium'
    enableRbacAuthorization: true
    enableSoftDelete: true
    softDeleteRetentionInDays: softDeleteRetentionDays
    enablePurgeProtection: true
    publicNetworkAccess: 'Disabled'
    networkAcls: {
      defaultAction: 'Deny'
      bypass: 'AzureServices'
    }
    privateEndpoints: [
      {
        name: 'pe-${name}-vault'
        subnetResourceId: privateEndpointSubnetResourceId
        privateDnsZoneGroup: {
          privateDnsZoneGroupConfigs: [
            {
              privateDnsZoneResourceId: privateDnsZoneResourceId
            }
          ]
        }
      }
    ]
    diagnosticSettings: [
      {
        name: 'diag-${name}'
        workspaceResourceId: logAnalyticsWorkspaceResourceId
        logCategoriesAndGroups: [
          { categoryGroup: 'audit' }
          { categoryGroup: 'allLogs' }
        ]
        metricCategories: [
          { category: 'AllMetrics' }
        ]
      }
    ]
    roleAssignments: vaultRoleAssignments
    keys: [
      {
        name: cmkKeyNames.storage
        kty: 'RSA'
        keySize: 3072
        rotationPolicy: rotationPolicy
      }
      {
        name: cmkKeyNames.documentIntelligence
        kty: 'RSA'
        keySize: 3072
        rotationPolicy: rotationPolicy
      }
      {
        name: cmkKeyNames.sqlTde
        kty: 'RSA'
        keySize: 3072
        rotationPolicy: rotationPolicy
      }
    ]
  }
}

@description('Resource ID of the Key Vault.')
output resourceId string = keyVault.outputs.resourceId

@description('Name of the Key Vault.')
output name string = keyVault.outputs.name

@description('URI of the Key Vault.')
output uri string = keyVault.outputs.uri

@description('Storage CMK key URI (versionless) for customerManagedKey parameters.')
output storageKeyUri string = '${keyVault.outputs.uri}keys/${cmkKeyNames.storage}'

@description('Document Intelligence CMK key URI (versionless) for customerManagedKey parameters.')
output documentIntelligenceKeyUri string = '${keyVault.outputs.uri}keys/${cmkKeyNames.documentIntelligence}'

@description('SQL TDE CMK key URI (versionless) for the encryption protector parameter.')
output sqlTdeKeyUri string = '${keyVault.outputs.uri}keys/${cmkKeyNames.sqlTde}'

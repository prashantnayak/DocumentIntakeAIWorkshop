// Thin wrapper over avm/res/cognitive-services/account for Document
// Intelligence (Form Recognizer). Keyless (Entra-only), private, and
// CMK-capable.
//
// OPEN DEPLOYMENT CHECK -- customer-managed keys are FEATURE-FLAGGED here
// (enableCustomerManagedKey, default false) rather than applied on the
// create call. Microsoft's official guidance for this resource type states:
// "When you create a new Foundry Tools resource, it's always encrypted by
// using Microsoft-managed keys. It's not possible to enable customer-managed
// keys when you create the resource." and "The managed identity is available
// only after the resource is created by using the pricing tier that's
// required for customer-managed keys."
// (https://learn.microsoft.com/azure/ai-services/document-intelligence/authentication/encrypt-data-at-rest)
// CMK itself IS supported for Document Intelligence resources created after
// 11 May 2020 on a paid tier -- the constraint is the ORDER of operations,
// not the SKU. Shipping the flag off by default therefore avoids a
// first-deployment failure while keeping the Key Vault key
// (cmk-documentintelligence) and the shared CMK identity provisioned and
// permissioned, ready for a second deployment pass with
// enableCustomerManagedKey=true once the account exists. See
// docs/COMPLIANCE.md and docs/ASSUMPTIONS.md.
metadata name = 'document-intelligence'
metadata description = 'Opinionated wrapper over AVM cognitive-services/account: Document Intelligence, keyless, private, with feature-flagged CMK applied on a second pass.'

@description('Document Intelligence account resource name.')
param name string

@description('Azure region for the account.')
param location string

@description('Common resource tags.')
param tags object

@minLength(1)
@maxLength(24)
@description('Globally-unique custom subdomain name, required for private endpoint support and Entra ID authentication.')
param customSubDomainName string

@allowed([
  'F0'
  'S0'
])
@description('Document Intelligence pricing tier.')
param skuName string

@description('Resource ID of the private-endpoint subnet.')
param privateEndpointSubnetResourceId string

@description('Resource ID of the privatelink.cognitiveservices.azure.com private DNS zone.')
param privateDnsZoneResourceId string

@description('Resource ID of the Log Analytics workspace for diagnostics.')
param logAnalyticsWorkspaceResourceId string

@description('Resource ID of the shared CMK user-assigned identity.')
param cmkIdentityResourceId string

@description('Resource ID of the Key Vault holding the Document Intelligence customer-managed key.')
param keyVaultResourceId string

@description('Name of the customer-managed key used to encrypt this account. Only applied when enableCustomerManagedKey is true.')
param cmkKeyName string

@description('Feature flag for customer-managed key encryption. Must be false on the first deployment (the account cannot be created with CMK already enabled) and can be set to true on a subsequent deployment pass once the account and its identity exist -- see the file header comment.')
param enableCustomerManagedKey bool

@description('Principal ID of the Function App identity, granted Cognitive Services User so it can call the data-plane analyze APIs.')
param functionIdentityPrincipalId string

@description('Optional Entra user object ID granted Cognitive Services User for interactive Document Intelligence Studio testing.')
param studioUserObjectId string = ''

var cognitiveServicesUserRoleId = 'a97b65f3-24c7-4388-baec-2e87135dc908'

module documentIntelligence 'br/public:avm/res/cognitive-services/account:0.19.0' = {
  name: take('cog-${name}-deploy', 64)
  params: {
    name: name
    location: location
    tags: tags
    kind: 'FormRecognizer'
    sku: skuName
    customSubDomainName: customSubDomainName
    disableLocalAuth: true
    publicNetworkAccess: 'Disabled'
    restrictOutboundNetworkAccess: false
    networkAcls: {
      defaultAction: 'Deny'
    }
    managedIdentities: {
      userAssignedResourceIds: [
        cmkIdentityResourceId
      ]
    }
    customerManagedKey: enableCustomerManagedKey
      ? {
          keyVaultResourceId: keyVaultResourceId
          keyName: cmkKeyName
          userAssignedIdentityResourceId: cmkIdentityResourceId
        }
      : null
    roleAssignments: concat(
      [
        {
          principalId: functionIdentityPrincipalId
          roleDefinitionIdOrName: cognitiveServicesUserRoleId
          principalType: 'ServicePrincipal'
          description: 'Allows the Function App to call Document Intelligence analyze/classify APIs using its managed identity.'
        }
      ],
      !empty(studioUserObjectId)
        ? [
            {
              principalId: studioUserObjectId
              roleDefinitionIdOrName: cognitiveServicesUserRoleId
              principalType: 'User'
              description: 'Allows the workshop operator to analyze synthetic documents interactively in Document Intelligence Studio.'
            }
          ]
        : []
    )
    privateEndpoints: [
      {
        name: 'pe-${name}-account'
        service: 'account'
        subnetResourceId: privateEndpointSubnetResourceId
        privateDnsZoneGroup: {
          privateDnsZoneGroupConfigs: [
            { privateDnsZoneResourceId: privateDnsZoneResourceId }
          ]
        }
      }
    ]
    diagnosticSettings: [
      {
        name: 'diag-${name}'
        workspaceResourceId: logAnalyticsWorkspaceResourceId
        logCategoriesAndGroups: [
          { categoryGroup: 'allLogs' }
        ]
        metricCategories: [
          { category: 'AllMetrics' }
        ]
      }
    ]
  }
}

@description('Resource ID of the Document Intelligence account.')
output resourceId string = documentIntelligence.outputs.resourceId

@description('Name of the Document Intelligence account.')
output name string = documentIntelligence.outputs.name

@description('Data-plane endpoint (private) of the Document Intelligence account.')
output endpoint string = documentIntelligence.outputs.endpoint

@description('True when this deployment applied a customer-managed key to the Document Intelligence account. False means the account is encrypted with Microsoft-managed keys and the CMK second pass is still outstanding.')
output customerManagedKeyApplied bool = enableCustomerManagedKey

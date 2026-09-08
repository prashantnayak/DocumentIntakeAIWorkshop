// Thin wrapper over avm/res/sql/server:0.22.0 and
// avm/res/sql/server/database:0.3.0. Entra ID-only authentication (SQL auth
// disabled), private endpoint, TDE protected by the shared Key Vault
// customer-managed key, auditing to Log Analytics, and long-term retention.
metadata name = 'sql'
metadata description = 'Opinionated wrapper over AVM sql/server + sql/server/database: Entra-only, private, TDE CMK, audited, LTR-protected serverless database.'

import { sqlDatabaseConfigType, entraGroupsConfigType } from '../types/shared-types.bicep'

@description('SQL logical server resource name.')
param serverName string

@description('SQL database name.')
param databaseName string

@description('Azure region.')
param location string

@description('Common resource tags.')
param tags object

@description('Azure AD tenant ID.')
param tenantId string

@description('Entra ID group configuration for the SQL administrator.')
param entraGroups entraGroupsConfigType

@description('Serverless compute and retention configuration.')
param databaseConfig sqlDatabaseConfigType

@description('Resource ID of the private-endpoint subnet.')
param privateEndpointSubnetResourceId string

@description('Resource ID of the privatelink.database.windows.net private DNS zone.')
param privateDnsZoneResourceId string

@description('Resource ID of the Log Analytics workspace for auditing and diagnostics.')
param logAnalyticsWorkspaceResourceId string

@description('Resource ID of the shared CMK user-assigned identity.')
param cmkIdentityResourceId string

@description('Resource ID of the Key Vault holding the SQL TDE customer-managed key.')
param keyVaultResourceId string

@description('Name of the customer-managed key used for TDE.')
param cmkKeyName string

@description('Resource ID of the (non-PHI) storage account used to store SQL vulnerability assessment scan reports.')
param vulnerabilityAssessmentStorageAccountResourceId string

@description('Resource ID of a public SQL maintenance window configuration for this region, e.g. .../publicMaintenanceConfigurations/SQL_EastUS2_DB_1. Verified to exist via az maintenance public-configuration list for the target region.')
param maintenanceConfigurationId string

var storageBlobDataContributorRoleId = subscriptionResourceId(
  'Microsoft.Authorization/roleDefinitions',
  'ba92f5b4-2d11-453d-a403-e96b0029c9fe'
)
var vulnerabilityAssessmentStorageAccountName = last(split(vulnerabilityAssessmentStorageAccountResourceId, '/'))

resource vulnerabilityAssessmentStorage 'Microsoft.Storage/storageAccounts@2025-06-01' existing = {
  name: vulnerabilityAssessmentStorageAccountName
}

module sqlServer 'br/public:avm/res/sql/server:0.22.0' = {
  name: take('sql-${serverName}-deploy', 64)
  params: {
    name: serverName
    location: location
    tags: tags
    administrators: {
      azureADOnlyAuthentication: true
      login: entraGroups.sqlAdminGroupName
      sid: entraGroups.sqlAdminGroupObjectId
      principalType: 'Group'
      tenantId: tenantId
    }
    publicNetworkAccess: 'Disabled'
    restrictOutboundNetworkAccess: 'Disabled'
    minimalTlsVersion: '1.2'
    managedIdentities: {
      systemAssigned: true
      userAssignedResourceIds: [
        cmkIdentityResourceId
      ]
    }
    primaryUserAssignedIdentityResourceId: cmkIdentityResourceId
    customerManagedKey: {
      keyVaultResourceId: keyVaultResourceId
      keyName: cmkKeyName
      userAssignedIdentityResourceId: cmkIdentityResourceId
      autoRotationEnabled: true
    }
    auditSettings: {
      state: 'Enabled'
      isAzureMonitorTargetEnabled: true
    }
    securityAlertPolicies: [
      {
        name: 'Default'
        state: 'Enabled'
      }
    ]
    privateEndpoints: [
      {
        name: 'pe-${serverName}-sqlserver'
        subnetResourceId: privateEndpointSubnetResourceId
        privateDnsZoneGroup: {
          privateDnsZoneGroupConfigs: [
            { privateDnsZoneResourceId: privateDnsZoneResourceId }
          ]
        }
      }
    ]
  }
}

resource vulnerabilityAssessmentStorageRole 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(vulnerabilityAssessmentStorageAccountResourceId, serverName, storageBlobDataContributorRoleId)
  scope: vulnerabilityAssessmentStorage
  properties: {
    principalId: sqlServer.outputs.systemAssignedMIPrincipalId!
    principalType: 'ServicePrincipal'
    roleDefinitionId: storageBlobDataContributorRoleId
    description: 'Allows the SQL server system-assigned identity to write vulnerability-assessment scan reports.'
  }
}

resource vulnerabilityAssessment 'Microsoft.Sql/servers/vulnerabilityAssessments@2025-01-01' = {
  name: '${serverName}/default'
  properties: {
    storageContainerPath: 'https://${vulnerabilityAssessmentStorageAccountName}.blob.${environment().suffixes.storage}/vulnerability-assessment/'
    recurringScans: {
      isEnabled: true
      emailSubscriptionAdmins: true
      emails: []
    }
  }
  dependsOn: [
    sqlServer
    vulnerabilityAssessmentStorageRole
  ]
}

module database 'br/public:avm/res/sql/server/database:0.3.0' = {
  name: take('sqldb-${databaseName}-deploy', 64)
  params: {
    name: databaseName
    location: location
    tags: tags
    serverName: sqlServer.outputs.name
    sku: {
      name: 'GP_S_Gen5'
      tier: 'GeneralPurpose'
      family: 'Gen5'
      capacity: databaseConfig.maxCapacity
    }
    // -1 maps to 'NoPreference' inside the module -- no dedicated
    // availability zone is pinned for this serverless workshop database.
    availabilityZone: -1
    autoPauseDelay: databaseConfig.autoPauseDelayMinutes
    minCapacity: string(databaseConfig.minCapacity)
    maxSizeBytes: 34359738368
    zoneRedundant: false
    collation: 'SQL_Latin1_General_CP1_CI_AS'
    maintenanceConfigurationId: maintenanceConfigurationId
    diagnosticSettings: [
      {
        name: 'diag-${databaseName}'
        workspaceResourceId: logAnalyticsWorkspaceResourceId
        logCategoriesAndGroups: [
          { categoryGroup: 'allLogs' }
        ]
        metricCategories: [
          { category: 'Basic' }
        ]
      }
    ]
    backupShortTermRetentionPolicy: {
      retentionDays: databaseConfig.shortTermRetentionDays
      diffBackupIntervalInHours: 24
    }
  }
}

@description('Resource ID of the SQL logical server.')
output serverResourceId string = sqlServer.outputs.resourceId

@description('Name of the SQL logical server.')
output serverName string = sqlServer.outputs.name

@description('Fully-qualified DNS name of the SQL logical server.')
output serverFqdn string = sqlServer.outputs.fullyQualifiedDomainName

@description('Resource ID of the SQL database.')
output databaseResourceId string = database.outputs.resourceId

@description('Name of the SQL database.')
output databaseName string = database.outputs.name

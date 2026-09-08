// Thin wrapper over avm/res/operational-insights/workspace.
// Analytics (hot) retention is capped at the workspace-level maximum of 730
// days. Medical-record-grade total retention (default 2556 days / 7 years)
// is achieved with the supported per-table archive mechanic (tables[].
// totalRetentionInDays), NOT an invalid >730-day workspace-level value.
metadata name = 'log-analytics'
metadata description = 'Opinionated wrapper over AVM operational-insights/workspace with per-table long-term (archive) retention for audit tables.'

import { logRetentionConfigType } from '../types/shared-types.bicep'

@description('Log Analytics workspace resource name.')
param name string

@description('Azure region for the workspace.')
param location string

@description('Common resource tags.')
param tags object

@description('Analytics vs. total (archive) retention configuration.')
param retention logRetentionConfigType

@description('Configure diagnostic-source tables that Azure creates only after their first records arrive. Enable on a later deployment after those tables have materialized.')
param configureLateBoundAuditTables bool = false

var auditTableNames = concat([
  'AzureActivity'
  'AppServiceHTTPLogs'
  'AppServiceConsoleLogs'
  'AppServiceAppLogs'
  'FunctionAppLogs'
  'SQLSecurityAuditEvents'
], configureLateBoundAuditTables ? [
  'AzureDiagnostics'
  'AKVAuditLogs'
  'NetworkSecurityGroupEvent'
] : [])

module workspace 'br/public:avm/res/operational-insights/workspace:0.16.1' = {
  name: take('log-${name}-deploy', 64)
  params: {
    name: name
    location: location
    tags: tags
    skuName: 'PerGB2018'
    dailyQuotaGb: '-1'
    dataRetention: retention.analyticsRetentionDays
    publicNetworkAccessForIngestion: 'Disabled'
    publicNetworkAccessForQuery: 'Disabled'
  }
}

// The current AVM table type caps this property at 2555, but the Azure API
// requires its exact seven-year value of 2556. Use the native child resource
// until the AVM schema adopts the API's supported value.
resource auditTables 'Microsoft.OperationalInsights/workspaces/tables@2025-02-01' = [
  for tableName in auditTableNames: {
    name: '${name}/${tableName}'
    properties: {
      retentionInDays: retention.analyticsRetentionDays
      totalRetentionInDays: retention.totalRetentionDays
    }
    dependsOn: [
      workspace
    ]
  }
]

@description('Resource ID of the Log Analytics workspace.')
output resourceId string = workspace.outputs.resourceId

@description('Name of the Log Analytics workspace.')
output name string = workspace.outputs.name

@description('Customer ID (workspace GUID) of the Log Analytics workspace.')
output customerId string = workspace.outputs.logAnalyticsWorkspaceId

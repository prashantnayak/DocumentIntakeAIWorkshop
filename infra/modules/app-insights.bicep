// Thin wrapper over avm/res/insights/component (Application Insights),
// workspace-based, ingesting via the Function App's managed identity
// (Monitoring Metrics Publisher) instead of an instrumentation key/
// connection-string secret wherever the SDK/exporter in use supports it.
metadata name = 'app-insights'
metadata description = 'Opinionated wrapper over AVM insights/component: workspace-based Application Insights with no exposed instrumentation secrets.'

@description('Application Insights resource name.')
param name string

@description('Azure region for the resource.')
param location string

@description('Common resource tags.')
param tags object

@description('Resource ID of the backing Log Analytics workspace.')
param logAnalyticsWorkspaceResourceId string

@description('Principal ID of the Function App identity, granted Monitoring Metrics Publisher so it can emit telemetry using Entra ID instead of an instrumentation key.')
param functionIdentityPrincipalId string

@description('Principal ID of the Logic App identity, granted Monitoring Metrics Publisher so run-history diagnostics can flow without a connection-string secret.')
param logicAppIdentityPrincipalId string

var monitoringMetricsPublisherRoleId = '3913510d-42f4-4e42-8a64-420c390055eb'

module appInsights 'br/public:avm/res/insights/component:0.8.0' = {
  name: take('appi-${name}-deploy', 64)
  params: {
    name: name
    location: location
    tags: tags
    kind: 'web'
    applicationType: 'web'
    workspaceResourceId: logAnalyticsWorkspaceResourceId
    disableIpMasking: false
    // Forces Entra ID (managed identity) ingestion/query only -- consistent
    // with the Monitoring Metrics Publisher role assignments below instead
    // of an instrumentation key.
    disableLocalAuth: true
    roleAssignments: [
      {
        principalId: functionIdentityPrincipalId
        roleDefinitionIdOrName: monitoringMetricsPublisherRoleId
        principalType: 'ServicePrincipal'
        description: 'Allows the Function App to publish telemetry using its managed identity instead of an instrumentation key.'
      }
      {
        principalId: logicAppIdentityPrincipalId
        roleDefinitionIdOrName: monitoringMetricsPublisherRoleId
        principalType: 'ServicePrincipal'
        description: 'Allows the Logic App to publish telemetry using its managed identity instead of an instrumentation key.'
      }
    ]
  }
}

@description('Resource ID of the Application Insights component.')
output resourceId string = appInsights.outputs.resourceId

@description('Name of the Application Insights component.')
output name string = appInsights.outputs.name

@description('Connection string. Not a secret by itself (ingestion endpoint + AppId), but app settings should still be sourced from this output rather than hardcoded.')
output connectionString string = appInsights.outputs.connectionString

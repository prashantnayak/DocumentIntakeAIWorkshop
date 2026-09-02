// Thin wrapper over avm/res/web/serverfarm (Workflow Standard WS1) and
// avm/res/web/site (kind 'functionapp,workflowapp') for the Logic Apps
// Standard host. Both a system-assigned identity (required by the Standard
// built-in Azure Blob Storage connector, which does not support selecting a
// user-assigned identity) and the shared user-assigned
// identity (used by the SQL Server built-in connector and HTTP/Graph calls)
// are enabled simultaneously -- see docs/COMPLIANCE.md for the platform
// citation behind this narrow, documented split.
metadata name = 'logic-app'
metadata description = 'Opinionated wrapper over AVM web/serverfarm + web/site: WS1 Logic Apps Standard, private, VNet-integrated, dual system+user-assigned identity.'

@description('App Service Plan resource name.')
param planName string

@description('Logic App resource name.')
param siteName string

@description('Azure region.')
param location string

@description('Common resource tags.')
param tags object

@minValue(1)
@maxValue(20)
@description('Workflow Standard plan worker count.')
param workerCount int

@description('Resource ID of the Logic App integration (delegated) subnet.')
param logicAppSubnetResourceId string

@description('Resource ID of the private-endpoint subnet.')
param privateEndpointSubnetResourceId string

@description('Resource ID of the privatelink.azurewebsites.net private DNS zone.')
param privateDnsZoneResourceId string

@description('Resource ID of the Log Analytics workspace for diagnostics.')
param logAnalyticsWorkspaceResourceId string

@description('Name of the runtime/host storage account (shared with Functions).')
param hostStorageAccountName string

@description('Resource ID of the runtime/host storage account.')
param hostStorageAccountResourceId string

@description('Name of the Azure Files content share dedicated to this Logic App.')
param contentShareName string

@description('Resource ID of the Logic App user-assigned identity (SQL Server built-in connector + HTTP/Graph calls).')
param logicAppIdentityResourceId string

@description('Client ID of the Logic App user-assigned identity. Used for the host-level AzureWebJobsStorage connection, which -- unlike the workflow-level built-in Blob connector -- fully supports user-assigned identity (see docs/COMPLIANCE.md).')
param logicAppIdentityClientId string

@minValue(1)
@maxValue(168)
@description('Hours a reviewer access link stays valid. Surfaced to workflows so reviewer emails can state the expiry explicitly and so the SLA workflow can warn when a link has already expired. See docs/runbook.md for the >= reviewEscalationAfterHours guidance.')
param sasLinkExpiryHours int

@description('Application Insights resource ID. Ingestion is auto-wired by the web/site module via applicationInsightResourceId (APPLICATIONINSIGHTS_CONNECTION_STRING is populated automatically and must not be set manually).')
param appInsightsResourceId string

@description('Business-rule configuration surfaced as workflow app settings; read by workflow parameters.json so rule values can change without redeploying workflow definitions.')
param confidenceThreshold string

@description('JSON-encoded array of high-risk document type labels.')
param highRiskDocumentTypes string[]

@description('JSON-encoded array of required field names.')
param requiredFields string[]

@minValue(1)
@maxValue(168)
param reviewReminderAfterHours int

@minValue(1)
@maxValue(336)
param reviewEscalationAfterHours int

@description('Fully-qualified Azure SQL server hostname.')
param sqlServerFqdn string

@description('Azure SQL database name.')
param sqlDatabaseName string

@description('Blob service URI (private) of the PHI storage account. Read by connections.json for the built-in Azure Blob service-provider connection.')
param phiStorageBlobServiceUri string

@description('Name of the PHI document container.')
param phiContainerName string

@description('Reviewer group email address (approval email recipient).')
param reviewerGroupEmail string

@description('Supervisor group email address (SLA escalation recipient).')
param supervisorGroupEmail string

@description('Resource ID of the Office 365 Outlook API connection used by the human-approval-workflow. Requires manual post-deploy OAuth consent -- see modules/api-connections.bicep.')
param office365ConnectionResourceId string

@description('Connector runtime URL of the Office 365 Outlook API connection.')
param office365ConnectionRuntimeUrl string

@description('Feature flag: opt-in SharePoint Online archive via Microsoft Graph.')
param enableSharePointArchive bool

@description('SharePoint Online site ID (Graph). Only meaningful when enableSharePointArchive is true.')
param sharePointSiteId string

@description('SharePoint Online drive (library) ID. Only meaningful when enableSharePointArchive is true.')
param sharePointDriveId string

@description('SharePoint Online archive root folder path. Only meaningful when enableSharePointArchive is true.')
param sharePointFolderPath string

// The AVM serverfarm module always emits maximumElasticWorkerCount, but Azure
// rejects that property when a WS1 plan is first created with zero workers.
// Use the native resource so the unsupported property is omitted.
resource plan 'Microsoft.Web/serverfarms@2025-03-01' = {
  name: planName
  location: location
  tags: tags
  kind: 'elastic'
  sku: {
    name: 'WS1'
    capacity: workerCount
  }
  properties: {
    reserved: false
    zoneRedundant: false
  }
}

#disable-next-line use-recent-api-versions
resource planDiagnostics 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = {
  scope: plan
  name: 'diag-${planName}'
  properties: {
    workspaceId: logAnalyticsWorkspaceResourceId
    metrics: [
      {
        category: 'AllMetrics'
        enabled: true
      }
    ]
  }
}

resource hostStorageAccount 'Microsoft.Storage/storageAccounts@2025-01-01' existing = {
  name: hostStorageAccountName
}

module site 'br/public:avm/res/web/site:0.24.0' = {
  name: take('logic-${siteName}-deploy', 64)
  params: {
    name: siteName
    location: location
    tags: tags
    kind: 'functionapp,workflowapp'
    serverFarmResourceId: plan.id
    managedIdentities: {
      systemAssigned: true
      userAssignedResourceIds: [
        logicAppIdentityResourceId
      ]
    }
    virtualNetworkSubnetResourceId: logicAppSubnetResourceId
    storageAccountRequired: false
    clientAffinityEnabled: false
    publicNetworkAccess: 'Disabled'
    httpsOnly: true
    privateEndpoints: [
      {
        name: 'pe-${siteName}-sites'
        subnetResourceId: privateEndpointSubnetResourceId
        service: 'sites'
        privateDnsZoneGroup: {
          privateDnsZoneGroupConfigs: [
            { privateDnsZoneResourceId: privateDnsZoneResourceId }
          ]
        }
      }
    ]
    diagnosticSettings: [
      {
        name: 'diag-${siteName}'
        workspaceResourceId: logAnalyticsWorkspaceResourceId
        logCategoriesAndGroups: [
          { categoryGroup: 'allLogs' }
        ]
        metricCategories: [
          { category: 'AllMetrics' }
        ]
      }
    ]
    configs: [
      {
        name: 'web'
        properties: {
          minTlsVersion: '1.2'
          ftpsState: 'Disabled'
          use32BitWorkerProcess: false
          alwaysOn: true
          http20Enabled: true
          vnetRouteAllEnabled: true
        }
      }
      {
        name: 'appsettings'
        // Identity-based AzureWebJobsStorage and Application Insights
        // ingestion are auto-wired by the module from
        // storageAccountResourceId/storageAccountUseIdentityAuthentication
        // and applicationInsightResourceId below -- AzureWebJobsStorage,
        // AzureWebJobsDashboard, APPINSIGHTS_INSTRUMENTATIONKEY, and
        // APPLICATIONINSIGHTS_CONNECTION_STRING must NOT be set in
        // properties (the module rejects/overwrites them).
        storageAccountResourceId: hostStorageAccountResourceId
        storageAccountUseIdentityAuthentication: true
        applicationInsightResourceId: appInsightsResourceId
        properties: {
          APP_KIND: 'workflowApp'
          FUNCTIONS_EXTENSION_VERSION: '~4'
          FUNCTIONS_WORKER_RUNTIME: 'node'
          WEBSITE_NODE_DEFAULT_VERSION: '~20'
          // Application Insights ingestion uses this Logic App's
          // user-assigned identity (Monitoring Metrics Publisher role)
          // because disableLocalAuth=true on the Application Insights
          // component.
          APPLICATIONINSIGHTS_AUTHENTICATION_STRING: 'Authorization=AAD;ClientId=${logicAppIdentityClientId}'
          WEBSITE_CONTENTSHARE: contentShareName
          // Logic Apps Standard is deployed with zip deploy (the documented,
          // supported path for this resource type -- unlike Azure Functions it
          // does not support running from an external package URL), so the
          // package is mounted read-only from the content share. Declared here
          // so an infrastructure redeployment never drops the setting the
          // code-deploy job depends on.
          WEBSITE_RUN_FROM_PACKAGE: '1'
          // Narrow, documented Shared Key exception -- see storage-runtime.bicep.
          WEBSITE_CONTENTAZUREFILECONNECTIONSTRING: 'DefaultEndpointsProtocol=https;AccountName=${hostStorageAccountName};AccountKey=${hostStorageAccount.listKeys().keys[0].value};EndpointSuffix=${environment().suffixes.storage}'
          WEBSITE_CONTENTOVERVNET: '1'
          // The module auto-generates AzureWebJobsStorage__accountName plus
          // blob/queue/table service URIs, but does not select which
          // identity to use -- explicitly select the Logic App's
          // USER-ASSIGNED identity here. This is the host-level WebJobs SDK
          // storage connection (trigger/lease state), which is distinct
          // from -- and fully supports user-assigned identity unlike -- the
          // workflow-level built-in Azure Blob connector used inside workflow
          // definitions (it requires system-assigned; see
          // docs/COMPLIANCE.md and modules/storage-container-role-assignment.bicep).
          AzureWebJobsStorage__credential: 'managedidentity'
          AzureWebJobsStorage__clientId: logicAppIdentityClientId
          // Workflow parameter surface (parameters.json reads these via
          // @appsetting(...) so rule values change without redeploying workflows).
          BusinessRules_ConfidenceThreshold: confidenceThreshold
          BusinessRules_HighRiskDocumentTypesJson: string(highRiskDocumentTypes)
          BusinessRules_RequiredFieldsJson: string(requiredFields)
          BusinessRules_ReviewReminderAfterHours: string(reviewReminderAfterHours)
          BusinessRules_ReviewEscalationAfterHours: string(reviewEscalationAfterHours)
          BusinessRules_AccessLinkExpiryHours: string(sasLinkExpiryHours)
          Sql_DataSource: sqlServerFqdn
          Sql_InitialCatalog: sqlDatabaseName
          // The SQL built-in (service provider) connector supports selecting a
          // user-assigned identity. Both the client ID and the full resource ID
          // are published so connections.json can name the intended identity
          // explicitly instead of relying on the host's default identity
          // resolution -- see src/logicapps/connections.json.
          Sql_UserAssignedIdentityClientId: logicAppIdentityClientId
          Sql_UserAssignedIdentityResourceId: logicAppIdentityResourceId
          // The built-in Azure Blob service-provider connection needs the PHI
          // account's blob endpoint. It authenticates with the Logic App
          // SYSTEM-ASSIGNED identity (the only identity type that built-in
          // connector supports) which is granted Storage Blob Data Contributor
          // on the documents container by
          // modules/storage-container-role-assignment.bicep.
          PhiStorage_BlobServiceUri: phiStorageBlobServiceUri
          PhiStorage_ContainerName: phiContainerName
          Reviewer_GroupEmail: reviewerGroupEmail
          Supervisor_GroupEmail: supervisorGroupEmail
          // Standard platform app settings some managed API connection
          // templates expect to be present; set explicitly rather than
          // relying on undocumented auto-population.
          WORKFLOWS_SUBSCRIPTION_ID: subscription().subscriptionId
          WORKFLOWS_RESOURCE_GROUP_NAME: resourceGroup().name
          WORKFLOWS_LOCATION_NAME: location
          Office365_ConnectionResourceId: office365ConnectionResourceId
          Office365_ConnectionRuntimeUrl: office365ConnectionRuntimeUrl
          SharePointArchive_Enabled: string(enableSharePointArchive)
          SharePointArchive_SiteId: sharePointSiteId
          SharePointArchive_DriveId: sharePointDriveId
          SharePointArchive_FolderPath: sharePointFolderPath
        }
      }
    ]
  }
}

@description('Resource ID of the Logic App.')
output resourceId string = site.outputs.resourceId

@description('Name of the Logic App.')
output name string = site.outputs.name

@description('Default (private) hostname of the Logic App.')
output defaultHostname string = site.outputs.defaultHostname

@description('Principal ID of the Logic Apps system-assigned identity used by the built-in Blob Storage connector.')
output systemAssignedPrincipalId string = site.outputs.?systemAssignedMIPrincipalId ?? ''

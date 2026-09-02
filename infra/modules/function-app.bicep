// Thin wrapper over avm/res/web/serverfarm (Elastic Premium EP1) and
// avm/res/web/site for a Python 3.12 Durable Function App on Linux. Private,
// VNet-integrated, identity-based storage connections, and no secrets in
// source-controlled application settings.
metadata name = 'function-app'
metadata description = 'Opinionated wrapper over AVM web/serverfarm + web/site: EP1 Python 3.12 Durable Function App, private, VNet-integrated, keyless data-plane connections.'

@description('App Service Plan resource name.')
param planName string

@description('Function App resource name.')
param siteName string

@description('Azure region.')
param location string

@description('Common resource tags.')
param tags object

@allowed([
  'EP1'
  'EP2'
  'EP3'
])
@description('Elastic Premium plan SKU.')
param skuName string

@minValue(1)
@maxValue(20)
@description('Minimum (always-ready) plan instance count.')
param minimumInstanceCount int

@minValue(1)
@maxValue(20)
@description('Maximum burst-out instance count.')
param maximumElasticInstanceCount int

@description('Resource ID of the Function integration (delegated) subnet.')
param functionSubnetResourceId string

@description('Resource ID of the private-endpoint subnet.')
param privateEndpointSubnetResourceId string

@description('Resource ID of the privatelink.azurewebsites.net private DNS zone.')
param privateDnsZoneResourceId string

@description('Resource ID of the Log Analytics workspace for diagnostics.')
param logAnalyticsWorkspaceResourceId string

@description('Name of the runtime/host storage account (shared with Logic Apps).')
param hostStorageAccountName string

@description('Resource ID of the runtime/host storage account.')
param hostStorageAccountResourceId string

@description('Name of the Azure Files content share dedicated to this Function App.')
param contentShareName string

@description('Resource ID of the Function App user-assigned identity.')
param functionIdentityResourceId string

@description('Client ID of the Function App user-assigned identity, used by identity-based Durable bindings and by application code for DefaultAzureCredential.')
param functionIdentityClientId string

@description('Resource ID of the Function App user-assigned identity used to fetch the run-from-package deployment package from private blob storage (WEBSITE_RUN_FROM_PACKAGE_BLOB_MI_RESOURCE_ID).')
param packagePullIdentityResourceId string

@description('Stable, versionless HTTPS URL of the Function deployment package in the private deployment-artifacts container. The package is published by .github/workflows/deploy.yml; until the first code deployment runs, the app has no package to load and reports a missing-package start-up error -- that is expected and is called out in the deploy job summary.')
param runFromPackageUrl string

@description('Application Insights resource ID. Ingestion is auto-wired by the web/site module via applicationInsightResourceId (APPLICATIONINSIGHTS_CONNECTION_STRING is populated automatically and must not be set manually).')
param appInsightsResourceId string

@description('Blob service URI (private) of the PHI storage account.')
param phiStorageBlobServiceUri string

@description('Name of the PHI document container.')
param phiContainerName string

@description('Blob prefix listed by the timer poller. The active deployment uses incoming; override with an isolated prefix only during a parallel migration.')
param phiIncomingPrefix string = 'incoming'

@description('Versionless Key Vault URI, including the trailing slash.')
param keyVaultUri string

@description('Key Vault secret containing the signed private business-rules workflow callback URL.')
param businessRulesCallbackSecretName string

@description('Data-plane endpoint (private) of the Document Intelligence account.')
param documentIntelligenceEndpoint string

@description('Document Intelligence model ID used for extraction (prebuilt-layout in Document Intelligence v4.0; prebuilt-document was removed in API version 2024-11-30).')
param documentIntelligenceModelId string

@description('Document Intelligence custom classifier model ID. Leave empty to use the deterministic extraction-based fallback classifier described in docs/architecture.md.')
param documentClassifierModelId string

@description('Fully-qualified Azure SQL server hostname, e.g. sql-intakeai-dev-eus2-xxxxx.database.windows.net.')
param sqlServerFqdn string

@description('Azure SQL database name.')
param sqlDatabaseName string

@description('Business-rule configuration surfaced as Function app settings for the deterministic fallback evaluator (the Logic Apps business-rules workflow remains authoritative -- see docs/ASSUMPTIONS.md).')
param confidenceThreshold string

@description('JSON-encoded array of high-risk document type labels.')
param highRiskDocumentTypes string[]

@description('JSON-encoded array of required field names.')
param requiredFields string[]

@minValue(1)
@maxValue(168)
@description('Hours a generated user-delegation SAS link remains valid in reviewer emails. Must be >= businessRules.reviewEscalationAfterHours. Capped at 168 because a user delegation key is valid for at most 7 days.')
param sasLinkExpiryHours int

module plan 'br/public:avm/res/web/serverfarm:0.7.0' = {
  name: take('asp-${planName}-deploy', 64)
  params: {
    name: planName
    location: location
    tags: tags
    skuName: skuName
    kind: 'elastic'
    reserved: true
    maximumElasticWorkerCount: maximumElasticInstanceCount
    // Workshop exception: this subscription has zero Sweden Central quota for
    // zone-redundant App Service workers. Keep EP1 elastic scaling, but deploy
    // the plan without zone redundancy until that quota is raised.
    zoneRedundant: false
    diagnosticSettings: [
      {
        name: 'diag-${planName}'
        workspaceResourceId: logAnalyticsWorkspaceResourceId
        metricCategories: [
          { category: 'AllMetrics' }
        ]
      }
    ]
  }
}

// The Azure Files content-share connection string is the one narrow,
// documented Shared Key exception described in storage-runtime.bicep. It is
// resolved at deploy time from the isolated runtime storage account and is
// never written to source control or emitted as a module output.
resource hostStorageAccount 'Microsoft.Storage/storageAccounts@2025-01-01' existing = {
  name: hostStorageAccountName
}

module site 'br/public:avm/res/web/site:0.24.0' = {
  name: take('func-${siteName}-deploy', 64)
  params: {
    name: siteName
    location: location
    tags: tags
    kind: 'functionapp,linux'
    serverFarmResourceId: plan.outputs.resourceId
    managedIdentities: {
      userAssignedResourceIds: [
        functionIdentityResourceId
      ]
    }
    keyVaultAccessIdentityResourceId: functionIdentityResourceId
    virtualNetworkSubnetResourceId: functionSubnetResourceId
    outboundVnetRouting: {
      allTraffic: true
      contentShareTraffic: true
      imagePullTraffic: true
    }
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
          linuxFxVersion: 'Python|3.12'
          use32BitWorkerProcess: false
          alwaysOn: true
          http20Enabled: true
          minimumElasticInstanceCount: minimumInstanceCount
          functionAppScaleLimit: maximumElasticInstanceCount
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
          FUNCTIONS_EXTENSION_VERSION: '~4'
          FUNCTIONS_WORKER_RUNTIME: 'python'
          AzureWebJobsFeatureFlags: 'EnableWorkerIndexing'
          PYTHON_ISOLATE_WORKER_DEPENDENCIES: '1'
          // Application Insights ingestion uses this Function's managed
          // identity (Monitoring Metrics Publisher role) because
          // disableLocalAuth=true on the Application Insights component.
          APPLICATIONINSIGHTS_AUTHENTICATION_STRING: 'Authorization=AAD;ClientId=${functionIdentityClientId}'
          WEBSITE_CONTENTSHARE: contentShareName
          // Narrow, documented Shared Key exception -- see file header comment.
          WEBSITE_CONTENTAZUREFILECONNECTIONSTRING: 'DefaultEndpointsProtocol=https;AccountName=${hostStorageAccountName};AccountKey=${hostStorageAccount.listKeys().keys[0].value};EndpointSuffix=${environment().suffixes.storage}'
          WEBSITE_CONTENTOVERVNET: '1'
          // Keep legacy App Service routing flags alongside
          // outboundVnetRouting for storage extensions that initialize before
          // the modern routing surface is applied.
          WEBSITE_VNET_ROUTE_ALL: '1'
          WEBSITE_DNS_SERVER: '168.63.129.16'
          // Code deployment: the app pulls its own package from the private
          // deployment-artifacts container with its user-assigned managed
          // identity (Storage Blob Data Reader on that container only). The
          // URL identifies an immutable SHA-256-addressed package so an
          // infrastructure redeployment preserves the exact published build.
          // See https://learn.microsoft.com/azure/azure-functions/run-functions-from-deployment-package
          WEBSITE_RUN_FROM_PACKAGE: runFromPackageUrl
          WEBSITE_RUN_FROM_PACKAGE_BLOB_MI_RESOURCE_ID: packagePullIdentityResourceId
          // The module auto-generates AzureWebJobsStorage__accountName plus
          // blob/queue/table service URIs from storageAccountResourceId +
          // storageAccountUseIdentityAuthentication above, but does not set
          // which identity to use -- explicitly select the Function App's
          // user-assigned identity here (default would otherwise be
          // ambiguous/system-assigned).
          AzureWebJobsStorage__credential: 'managedidentity'
          AzureWebJobsStorage__clientId: functionIdentityClientId
          // Application code lists the private PHI Blob endpoint directly on
          // a timer; no Blob trigger extension, PHI queue, or scan logs exist.
          PhiStorage__blobServiceUri: phiStorageBlobServiceUri
          PhiStorage__clientId: functionIdentityClientId
          // Application configuration: endpoints and identifiers only.
          ManagedIdentity__ClientId: functionIdentityClientId
          PhiStorage__ContainerName: phiContainerName
          PhiStorage__IncomingPrefix: phiIncomingPrefix
          PhiStorage__FailedPrefix: 'failed'
          PhiStorage__WorkflowPayloadPrefix: 'workflow-payloads'
          IntakePollingSchedule: '0 */1 * * * *'
          IntakePollingBatchSize: '100'
          ReconciliationSchedule: '0 */15 * * * *'
          ReconciliationStaleMinutes: '15'
          DocumentIntelligence__Endpoint: documentIntelligenceEndpoint
          DocumentIntelligence__ExtractionModelId: documentIntelligenceModelId
          DocumentIntelligence__ClassifierModelId: documentClassifierModelId
          Sql__DataSource: sqlServerFqdn
          Sql__InitialCatalog: sqlDatabaseName
          BusinessRules__ConfidenceThreshold: confidenceThreshold
          BusinessRules__HighRiskDocumentTypesJson: string(highRiskDocumentTypes)
          BusinessRules__RequiredFieldsJson: string(requiredFields)
          BusinessRules__SasLinkExpiryHours: string(sasLinkExpiryHours)
          BusinessRulesWorkflowUrl: '@Microsoft.KeyVault(SecretUri=${keyVaultUri}secrets/${businessRulesCallbackSecretName})'
        }
      }
    ]
  }
}

@description('Resource ID of the Function App.')
output resourceId string = site.outputs.resourceId

@description('Name of the Function App.')
output name string = site.outputs.name

@description('Default (private) hostname of the Function App.')
output defaultHostname string = site.outputs.defaultHostname

// Development/workshop environment parameters for the Document Intake AI
// pipeline. Sweden Central, single environment, <1,000 documents/day.
//
// Values marked "REPLACE-BEFORE-DEPLOY" are genuine deployment-time inputs
// that cannot be safely defaulted (tenant-specific object IDs, mailboxes,
// SharePoint site/library identifiers). See docs/ASSUMPTIONS.md for the full
// list of open questions to resolve before first deploy.
using '../main.bicep'

param location = 'swedencentral'
param regionCode = 'swc'
param workloadName = 'intakeai'
param environmentName = 'dev'

param tags = {
  application: 'intakeai'
  environment: 'dev'
  dataClassification: 'PHI'
  costCenter: 'REPLACE-BEFORE-DEPLOY-cost-center'
  owner: 'REPLACE-BEFORE-DEPLOY-team-distribution-list'
  sourceRepo: 'https://github.com/REPLACE-BEFORE-DEPLOY/DocumentIntakeAIWorkshop'
}

param networkConfig = {
  addressSpace: '10.60.0.0/16'
  functionIntegrationSubnetPrefix: '10.60.0.0/26'
  logicAppIntegrationSubnetPrefix: '10.60.0.64/26'
  privateEndpointSubnetPrefix: '10.60.1.0/24'
}

// Optional workshop-only private Windows VM and free Developer Bastion.
// Keep disabled in normal deployments; scripts/deploy-test-access.ps1 enables
// it with a generated temporary password and the signed-in user's object ID.
param enableTestAccess = false
param testVmSubnetPrefix = '10.60.2.0/24'
param testVmSize = 'Standard_D2s_v5'
param testVmAdminUsername = 'testadmin'

// --- Key Vault ---
param keyVaultSoftDeleteRetentionDays = 90

// --- Storage ---
param phiStorageSoftDeleteRetentionDays = 30
param enableImmutabilityPolicy = false
param immutabilityRetentionDays = 2555
param documentContainerName = 'documents'
param functionContentShareName = 'funcpy-content'
param logicAppContentShareName = 'logic-v2-content'
param deploymentArtifactsContainerName = 'deployment-artifacts'
// Object ID of the CI/CD service principal that publishes application
// packages (printed by scripts/bootstrap.ps1). Layered on at deploy time from
// the AZURE_DEPLOYER_OBJECT_ID environment secret so no tenant-specific
// identifier is committed; empty here means "skip the container-scoped
// publisher grant", which is correct for a what-if run.
param deploymentArtifactsPublisherObjectId = ''

// --- Durable Blob intake ---
param functionIncomingPrefix = 'incoming-v2'
param businessRulesCallbackSecretName = 'logic-business-rules-callback'

// --- Document Intelligence ---
// Workshop scale (<1,000 docs/day) uses the S0 standard tier so throughput
// is not throttled to the free tier's per-month cap.
param documentIntelligenceSkuName = 'S0'
// Document Intelligence v4.0 (API version 2024-11-30, which
// Azure.AI.DocumentIntelligence 1.0.0 targets) removed prebuilt-document.
// prebuilt-layout plus the keyValuePairs add-on feature is its replacement
// and is what src/functions requests.
param documentIntelligenceExtractionModelId = 'prebuilt-layout'
// Empty by default: no trained custom classifier model exists yet for this
// workshop. The Function falls back to the deterministic, extraction-based
// classifier described in docs/architecture.md until a classifier model ID
// is supplied here.
param documentIntelligenceClassifierModelId = ''
// OPEN DEPLOYMENT CHECK: Microsoft documents that a Document Intelligence
// resource is always created with Microsoft-managed keys and that CMK cannot
// be enabled on the create call, so this stays false for the first
// deployment. The Key Vault key and CMK identity are provisioned regardless;
// re-run the deployment with true once the account exists to complete the
// CMK second pass. See infra/modules/document-intelligence.bicep.
param enableDocumentIntelligenceCmk = false

// --- Compute ---
param functionAppSkuName = 'EP1'
param functionMinimumInstanceCount = 1
param functionMaximumElasticInstanceCount = 3
param logicAppWorkerCount = 1
// Must be >= businessRules.reviewEscalationAfterHours (72) so the read-only
// link in a reviewer email is still valid when a supervisor is asked to
// action it at escalation time. The link resolves through the PHI storage
// private endpoint, so it only opens from a VNet-connected reviewer endpoint
// -- see docs/runbook.md "Reviewer document links".
param sasLinkExpiryHours = 72

// --- Business rules (Logic Apps business-rules workflow is authoritative;
// the Function reads the same values for its deterministic fallback) ---
param businessRules = {
  confidenceThreshold: '0.85'
  highRiskDocumentTypes: [
    'Consent Form'
    'Advance Directive'
    'Prior Authorization'
  ]
  requiredFields: [
    'PatientIdentifier'
    'DateOfService'
    'Provider'
  ]
  reviewReminderAfterHours: 24
  reviewEscalationAfterHours: 72
}

// --- SQL ---
param sqlDatabaseName = 'sqldb-intake'
param maintenanceConfigurationName = 'SQL_SwedenCentral_DB_1'
param sqlDatabaseConfig = {
  minCapacity: 1
  maxCapacity: 2
  autoPauseDelayMinutes: 60
  shortTermRetentionDays: 35
}

// --- Identity / access (REPLACE-BEFORE-DEPLOY: genuine tenant-specific inputs) ---
param entraGroups = {
  sqlAdminGroupObjectId: '00000000-0000-0000-0000-000000000001'
  sqlAdminGroupName: 'REPLACE-BEFORE-DEPLOY-sg-intakeai-sql-admins'
  reviewerGroupObjectId: '00000000-0000-0000-0000-000000000002'
  reviewerGroupEmail: 'REPLACE-BEFORE-DEPLOY-intake-reviewers@example.com'
  supervisorGroupObjectId: '00000000-0000-0000-0000-000000000003'
  supervisorGroupEmail: 'REPLACE-BEFORE-DEPLOY-intake-supervisors@example.com'
}

// --- Observability ---
param logRetention = {
  analyticsRetentionDays: 90
  totalRetentionDays: 2556
}

param alerting = {
  operationsEmail: 'REPLACE-BEFORE-DEPLOY-intake-ops@example.com'
  webhookUri: ''
}
param criticalAlertSeverity = 1
param slaAlertSeverity = 2
param keyVaultAnomalyThreshold = 5

// --- Optional features ---
// SharePoint archive is opt-in and disabled by default; the pipeline
// deploys and functions fully without it, per the confirmed requirement.
param sharePointArchive = {
  enabled: false
  siteId: ''
  driveId: ''
  folderPath: '/IntakeArchive'
}

// HIPAA/HITRUST policy assignment and Defender for Cloud plans are
// feature-flagged off by default in this shared/workshop subscription
// because of blast radius and cost -- see docs/ASSUMPTIONS.md and
// docs/COMPLIANCE.md. Enable deliberately once the subscription owner has
// reviewed scope and cost impact.
param governance = {
  enableHipaaHitrustPolicy: false
  policyEnforcementMode: 'DoNotEnforce'
  enableDefenderForCloud: false
  defenderPlanNames: [
    'StorageAccounts'
    'SqlServers'
    'AppServices'
    'KeyVaults'
    'Arm'
    'Dns'
  ]
}

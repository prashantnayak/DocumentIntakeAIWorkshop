// Shared user-defined types for the Document Intake AI workshop environment.
// Centralizing types here lets every module and the subscription-scoped
// orchestrator (main.bicep) import a single, consistent contract instead of
// redefining object/array shapes per module.
//
// Decorator usage follows Bicep's actual per-type support:
//   - @minLength/@maxLength -> string and array types only
//   - @minValue/@maxValue   -> int type only
//   - @secure()             -> string and object types only
//   - @allowed              -> any type, used here for string enums
//   - @sealed()             -> object types, to reject unexpected properties

@export()
@sealed()
@description('Common CAF-aligned resource tags applied to every module call. DataClassification is always PHI for this workload.')
type resourceTagsType = {
  @description('Logical application/workload name shown in tags, e.g. intakeai.')
  application: string

  @description('Deployment environment name, e.g. dev, test, prod.')
  environment: string

  @description('Data classification tag. Must remain PHI for every resource in this workload.')
  dataClassification: string

  @description('Cost center or billing owner tag used for chargeback reporting.')
  costCenter: string

  @description('Team, distribution list, or on-call owner responsible for the resource.')
  owner: string

  @description('Source repository URL, used to trace deployed resources back to this IaC repo.')
  sourceRepo: string
}

@export()
@sealed()
@description('Naming context passed to the centralized naming user-defined functions in modules/naming.bicep.')
type namingContextType = {
  @minLength(2)
  @maxLength(12)
  @description('Short workload token used in every resource name, e.g. intakeai.')
  workloadName: string

  @minLength(2)
  @maxLength(10)
  @description('Short environment token used in every resource name, e.g. dev, test, prod.')
  environmentName: string

  @minLength(2)
  @maxLength(10)
  @description('Short region code used in every resource name, e.g. swc for Sweden Central.')
  regionCode: string

  @minLength(3)
  @maxLength(13)
  @description('Deterministic unique suffix (derived from subscription + resource group + workload) appended to globally-unique resource names such as Storage, Key Vault, SQL, and Azure AI.')
  uniqueSuffix: string
}

@export()
@sealed()
@description('Address prefixes for the private network boundary. All values are CIDR blocks.')
type networkConfigType = {
  @minLength(9)
  @maxLength(18)
  @description('VNet address space, e.g. 10.60.0.0/16.')
  addressSpace: string

  @minLength(9)
  @maxLength(18)
  @description('Delegated subnet CIDR for the Azure Functions Elastic Premium VNet integration.')
  functionIntegrationSubnetPrefix: string

  @minLength(9)
  @maxLength(18)
  @description('Delegated subnet CIDR for the Logic Apps Standard VNet integration.')
  logicAppIntegrationSubnetPrefix: string

  @minLength(9)
  @maxLength(18)
  @description('Subnet CIDR dedicated to private endpoints for every private data-plane service.')
  privateEndpointSubnetPrefix: string
}

@export()
@sealed()
@description('Parameterized business-rule thresholds. The Logic Apps business-rules workflow is the authoritative evaluator of these values; the Function app reads the same values to compute a deterministic fallback/pre-routing decision. Confidence is modeled as a string because neither Azure Functions app settings nor Logic Apps workflow parameters support a native decimal type at the platform level.')
type businessRulesConfigType = {
  @minLength(1)
  @maxLength(4)
  @description('Classification confidence threshold (0.0-1.0, e.g. "0.85"). Below this value a document always routes to human review.')
  confidenceThreshold: string

  @minLength(1)
  @description('Document classification labels that always route to human review regardless of confidence, e.g. Consent Form, Advance Directive, Prior Authorization.')
  highRiskDocumentTypes: string[]

  @minLength(1)
  @description('Names of mandatory extracted fields. If any is missing or empty the document routes to human review, e.g. PatientIdentifier, DateOfService, Provider.')
  requiredFields: string[]

  @minValue(1)
  @maxValue(168)
  @description('Hours after which an un-actioned review item receives a reminder notification (default 24).')
  reviewReminderAfterHours: int

  @minValue(1)
  @maxValue(336)
  @description('Hours after which an un-actioned review item escalates to the supervisor group (default 72). Must be greater than reviewReminderAfterHours.')
  reviewEscalationAfterHours: int
}

@export()
@sealed()
@description('Log Analytics retention split between hot analytics retention and total (analytics + archive) retention. Total retention satisfies the seven-year medical-record requirement using supported per-table archive mechanics, not an unsupported workspace-level value.')
type logRetentionConfigType = {
  @minValue(30)
  @maxValue(730)
  @description('Interactive analytics retention in days (workspace maximum is 730 days).')
  analyticsRetentionDays: int

  @minValue(365)
  @maxValue(2556)
  @description('Total retention in days including long-term archive, applied per-table. Azure requires values beyond two years to use its exact supported full-year day counts; 2556 is the accepted seven-year value. The portal supports up to 4383 days (12 years), but that path is out of scope for this IaC repo.')
  totalRetentionDays: int
}

@export()
@sealed()
@description('Azure SQL Database serverless compute and retention configuration.')
type sqlDatabaseConfigType = {
  @minValue(1)
  @maxValue(80)
  @description('Serverless minimum vCore capacity.')
  minCapacity: int

  @minValue(1)
  @maxValue(80)
  @description('Serverless maximum vCore capacity.')
  maxCapacity: int

  @minValue(60)
  @maxValue(10080)
  @description('Auto-pause delay in minutes for the serverless database (60 minimum, or -1 semantics handled by caller to disable).')
  autoPauseDelayMinutes: int

  @minValue(1)
  @maxValue(35)
  @description('Point-in-time-restore short-term backup retention in days.')
  shortTermRetentionDays: int

}

@export()
@sealed()
@description('Entra ID group object IDs used for SQL administration and workflow access. These are deployment-time inputs and are never invented defaults.')
type entraGroupsConfigType = {
  @minLength(36)
  @maxLength(36)
  @description('Object ID of the Entra ID group granted Azure SQL administrator access (Entra-only authentication).')
  sqlAdminGroupObjectId: string

  @minLength(1)
  @maxLength(256)
  @description('Display name of the Azure SQL Entra administrator group, shown on the logical server.')
  sqlAdminGroupName: string

  @minLength(36)
  @maxLength(36)
  @description('Object ID of the Entra ID group granted access to the human-review experience (reviewers).')
  reviewerGroupObjectId: string

  @minLength(3)
  @maxLength(320)
  @description('Email address (or mail-enabled security group address) that receives reviewer approval emails and reminders.')
  reviewerGroupEmail: string

  @minLength(36)
  @maxLength(36)
  @description('Object ID of the Entra ID group that receives SLA escalation notifications (supervisors).')
  supervisorGroupObjectId: string

  @minLength(3)
  @maxLength(320)
  @description('Email address (or mail-enabled security group address) that receives SLA escalation notifications.')
  supervisorGroupEmail: string
}

@export()
@sealed()
@description('Action group receivers for Azure Monitor alert routing. No secrets are carried in this type; webhook URIs must not embed credentials.')
type alertingConfigType = {
  @minLength(1)
  @maxLength(320)
  @description('Primary operations email address that receives all platform alerts.')
  operationsEmail: string

  @description('Optional webhook URI (e.g. an ITSM or ChatOps integration) that receives alert payloads. Leave empty to disable.')
  webhookUri: string
}

@export()
@sealed()
@description('Opt-in SharePoint Online archive feature configuration. Ignored entirely when enabled is false.')
type sharePointArchiveConfigType = {
  @description('Feature flag. When false, no SharePoint/Graph resources or workflow branches are activated.')
  enabled: bool

  @description('SharePoint Online site ID (Microsoft Graph site resource ID, e.g. contoso.sharepoint.com,<siteGuid>,<webGuid>). Required only when enabled is true.')
  siteId: string

  @description('SharePoint Online document library (drive) ID. Required only when enabled is true.')
  driveId: string

  @description('Root folder path within the document library where approved documents are archived, e.g. /IntakeArchive.')
  folderPath: string
}

@export()
@sealed()
@description('Governance feature flags for HIPAA/HITRUST policy assignment and Microsoft Defender for Cloud plans. Feature-flagged because both carry subscription-wide blast radius and cost in a shared subscription.')
type governanceConfigType = {
  @description('When true, assigns the built-in HIPAA HITRUST regulatory compliance initiative at subscription scope.')
  enableHipaaHitrustPolicy: bool

  @minLength(1)
  @description('Policy enforcement mode applied to the initiative assignment, e.g. Default or DoNotEnforce.')
  policyEnforcementMode: string

  @description('When true, enables the listed Microsoft Defender for Cloud plans at subscription scope.')
  enableDefenderForCloud: bool

  @minLength(1)
  @description('Defender for Cloud plan names to enable when enableDefenderForCloud is true, e.g. StorageAccounts, SqlServers, AppServices, KeyVaults, Arm, Dns.')
  defenderPlanNames: string[]
}

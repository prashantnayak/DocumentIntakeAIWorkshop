// Thin wrapper over avm/res/web/connection for the Office 365 Outlook
// managed API connection used by the human-approval-workflow's "Send
// approval email" action.
//
// IMPORTANT / MANUAL POST-DEPLOY STEP: Bicep can create the connection
// resource shell, but Office 365 uses interactive OAuth. Azure Resource
// Manager cannot complete that sign-in non-interactively. After deployment,
// a workload owner MUST open this connection in the Azure portal (Logic App
// -> API connections -> office365 -> "Edit API connection" -> Authorize) and
// sign in as the mailbox/service account that should send approval emails,
// or the human-approval-workflow will fail at runtime with an
// unauthenticated-connection error. See docs/runbook.md.
metadata name = 'api-connections'
metadata description = 'Opinionated wrapper over AVM web/connection: Office 365 Outlook connection shell. Requires manual post-deploy OAuth consent (documented, cannot be automated by Bicep/ARM).'

@description('Azure region for the connection resource.')
param location string

@description('Common resource tags.')
param tags object

@description('Name of the Office 365 Outlook API connection resource.')
param office365ConnectionName string

@description('Display name shown in the Azure portal consent/authorization experience.')
param office365ConnectionDisplayName string

var office365ManagedApiId = subscriptionResourceId('Microsoft.Web/locations/managedApis', location, 'office365')

module office365Connection 'br/public:avm/res/web/connection:0.4.4' = {
  name: take('con-${office365ConnectionName}-deploy', 64)
  params: {
    name: office365ConnectionName
    location: location
    tags: tags
    // Logic Apps Standard requires a V2 connection. V1 connections reject the
    // managed-identity access policy used by the workflow host.
    kind: 'V2'
    displayName: office365ConnectionDisplayName
    api: {
      id: office365ManagedApiId
    }
  }
}

@description('Resource ID of the Office 365 Outlook connection. Grant the Logic App identity an access policy on it and complete interactive consent post-deploy -- see file header comment and modules/connection-access-policy.json.')
output office365ConnectionResourceId string = office365Connection.outputs.resourceId

@description('Name of the Office 365 Outlook connection.')
output office365ConnectionName string = office365Connection.outputs.name

@description('Connector runtime URL placeholder. Office 365 does not populate this property until interactive consent; update the Logic App setting after authorization as documented in docs/runbook.md.')
output office365ConnectionRuntimeUrl string = ''

@description('Reminder that this connection requires manual, interactive OAuth consent after deployment before the human-approval-workflow can send mail.')
output postDeployConsentRequired bool = true

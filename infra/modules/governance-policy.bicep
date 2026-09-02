// Thin wrapper over avm/res/authorization/policy-assignment/sub-scope.
// Assigns the built-in "HITRUST/HIPAA" regulatory compliance initiative at
// subscription scope. Feature-flagged (enableHipaaHitrustPolicy) because, in
// a shared subscription, the assignment's evaluation and any future
// remediation carry blast radius and cost beyond this workload alone.
targetScope = 'subscription'

metadata name = 'governance-policy'
metadata description = 'Opinionated, feature-flagged wrapper over AVM authorization/policy-assignment/sub-scope: built-in HITRUST/HIPAA initiative.'

@description('Azure region used for the policy assignment metadata (no regional resources are created).')
param location string

@description('Feature flag. When false, no policy assignment is created.')
param enableHipaaHitrustPolicy bool

@minLength(1)
@description('Policy enforcement mode, e.g. Default or DoNotEnforce.')
param policyEnforcementMode string

var hipaaHitrustInitiativeId = '/providers/Microsoft.Authorization/policySetDefinitions/a169a624-5599-4385-a696-c8d643089fab'

module policyAssignment 'br/public:avm/res/authorization/policy-assignment/sub-scope:0.1.0' = if (enableHipaaHitrustPolicy) {
  name: take('policy-hipaa-hitrust-deploy', 64)
  params: {
    name: 'hipaa-hitrust-intakeai'
    displayName: 'HITRUST/HIPAA regulatory compliance (Document Intake AI)'
    description: 'Built-in HITRUST/HIPAA regulatory compliance initiative, scoped to evidence-gathering for the Document Intake AI workload. Azure Policy compliance reflects only the specific control mappings in this initiative and does not by itself confer HIPAA compliance -- see docs/COMPLIANCE.md.'
    location: location
    policyDefinitionId: hipaaHitrustInitiativeId
    enforcementMode: policyEnforcementMode
  }
}

@description('Resource ID of the policy assignment, or empty when the feature flag is disabled.')
output policyAssignmentResourceId string = policyAssignment.?outputs.resourceId ?? ''

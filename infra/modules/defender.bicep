// Raw ARM resource: Microsoft.Security/pricings.
// No AVM module exists for Microsoft Defender for Cloud pricing plans
// (confirmed absent from avm/res/security -- the directory does not exist,
// and the resource type has no entry in the AVM module CSV index), so this
// is a deliberate, documented exception to the "prefer AVM" rule. One
// resource declaration is required per plan name; Bicep's for-loop handles
// the fan-out that raw ARM templates would need one resource block each for.
targetScope = 'subscription'

metadata name = 'defender'
metadata description = 'RAW ARM (no AVM module exists for Microsoft.Security/pricings), feature-flagged: Microsoft Defender for Cloud plans.'

@description('Feature flag. When false, no Defender for Cloud plans are modified by this deployment.')
param enableDefenderForCloud bool

@minLength(1)
@description('Defender for Cloud plan names to enable, e.g. StorageAccounts, SqlServers, AppServices, KeyVaults, Arm, Dns.')
param defenderPlanNames array

resource defenderPlans 'Microsoft.Security/pricings@2024-01-01' = [
  for planName in (enableDefenderForCloud ? defenderPlanNames : []): {
    name: planName
    properties: {
      pricingTier: 'Standard'
    }
  }
]

@description('Names of the Defender for Cloud plans this deployment enabled (empty when the feature flag is disabled).')
output enabledPlanNames array = enableDefenderForCloud ? defenderPlanNames : []

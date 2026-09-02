// Centralized CAF (Cloud Adoption Framework) naming and tagging.
// Every module in this repository derives its resource name and tags from
// the user-defined functions in this file so that naming stays consistent
// and is never hardcoded per-module.
//
// Pattern for dashed resource names: <abbr>-<workload>-<env>-<region>[-<uniqueSuffix>]
// Pattern for alphanumeric-only resources (Storage): <abbr><workload><env><region><uniqueSuffix>, truncated.

import { namingContextType, resourceTagsType } from '../types/shared-types.bicep'

@export()
@description('Builds a standard dashed CAF resource name: <abbr>-<workload>-<env>-<region>, optionally with the deterministic unique suffix appended for globally-unique resource types.')
func buildName(abbr string, ctx namingContextType, includeUniqueSuffix bool) string =>
  includeUniqueSuffix
    ? '${abbr}-${ctx.workloadName}-${ctx.environmentName}-${ctx.regionCode}-${ctx.uniqueSuffix}'
    : '${abbr}-${ctx.workloadName}-${ctx.environmentName}-${ctx.regionCode}'

@export()
@description('Builds a lowercase, dash-free alphanumeric name for resource types that forbid dashes and require global uniqueness (Storage accounts). Always preserves the abbreviation prefix and the full deterministic unique suffix, truncating only the workload token in the middle so uniqueness is never lost to truncation.')
func buildAlphanumericName(abbr string, ctx namingContextType, maxLength int) string =>
  toLower('${abbr}${take(ctx.workloadName, max(maxLength - length(abbr) - length(ctx.uniqueSuffix), 0))}${ctx.uniqueSuffix}')

@export()
@description('Builds the deterministic child resource name for a private endpoint targeting a given parent resource abbreviation and group ID, e.g. pe-st-intakeai-dev-eus2-blob.')
func buildPrivateEndpointName(parentAbbr string, ctx namingContextType, groupId string) string =>
  'pe-${parentAbbr}-${ctx.workloadName}-${ctx.environmentName}-${ctx.regionCode}-${groupId}'

@export()
@description('Converts the shared resourceTagsType into the plain tags dictionary object every AVM module/resource accepts. DataClassification is intentionally capitalized to match the HIPAA evidence tag key requested for this workload.')
func buildTags(tags resourceTagsType) object => {
  application: tags.application
  environment: tags.environment
  DataClassification: tags.dataClassification
  costCenter: tags.costCenter
  owner: tags.owner
  sourceRepo: tags.sourceRepo
  managedBy: 'bicep-avm'
}

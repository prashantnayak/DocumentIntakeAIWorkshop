# Shared helper -- dot-source this file, then call Get-ExtraDeploymentParameters.
#
# Tenant-specific object IDs, e-mail addresses, and tags are intentionally
# left as REPLACE-BEFORE-DEPLOY placeholders in infra/params/*.bicepparam
# (see docs/ASSUMPTIONS.md) so no tenant-specific identifier is ever
# committed to source control. CI layers the real values on top from
# environment secrets, each supplied as a JSON object matching the
# corresponding parameter's type in infra/types/shared-types.bicep.
#
# Required GitHub Environment secrets (all optional -- omitted secrets
# leave the corresponding infra/params/*.bicepparam placeholder value in
# effect, which is only safe for what-if, not for an actual create):
#   AZURE_ENTRA_GROUPS_JSON  -> entraGroupsConfigType JSON
#   AZURE_ALERTING_JSON      -> alertingConfigType JSON
#   AZURE_TAGS_JSON          -> resourceTagsType JSON
#   AZURE_DEPLOYER_OBJECT_ID -> service principal OBJECT id (printed by
#                               scripts/bootstrap.ps1). Grants the deployment
#                               principal Storage Blob Data Contributor scoped
#                               to the private deployment-artifacts container
#                               only, which is how deploy.yml publishes the
#                               Function and Logic App packages. Omit it and
#                               the code-deploy job cannot upload.
function Get-ExtraDeploymentParameters {
    $extraArgs = @()
    if ($env:ENTRA_GROUPS_JSON) { $extraArgs += @('--parameters', "entraGroups=$($env:ENTRA_GROUPS_JSON)") }
    if ($env:ALERTING_JSON) { $extraArgs += @('--parameters', "alerting=$($env:ALERTING_JSON)") }
    if ($env:TAGS_JSON) { $extraArgs += @('--parameters', "tags=$($env:TAGS_JSON)") }
    if ($env:DEPLOYER_OBJECT_ID) { $extraArgs += @('--parameters', "deploymentArtifactsPublisherObjectId=$($env:DEPLOYER_OBJECT_ID)") }
    return $extraArgs
}

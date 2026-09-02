// RAW ARM (no AVM module covers role assignments scoped to an arbitrary
// child resource such as a single blob container -- the AVM authorization
// role-assignment modules only cover subscription, resource-group, and
// management-group scope). Grants a role on one blob container only, so a
// principal never receives storage-account-wide (let alone subscription-
// wide) access.
metadata name = 'storage-container-role-assignment'
metadata description = 'RAW ARM: role assignment scoped to a single blob container. Used to grant the Logic App system-assigned identity access after the Logic App (and therefore its identity) exists.'

@description('Name of the storage account containing the target container.')
param storageAccountName string

@description('Name of the blob container to scope the role assignment to.')
param containerName string

@description('Principal ID receiving the role.')
param principalId string

@description('Principal type, e.g. ServicePrincipal.')
param principalType string = 'ServicePrincipal'

@description('Role definition GUID (not the full resource ID) to assign.')
param roleDefinitionId string

@description('Human-readable description stored on the role assignment for audit purposes.')
param roleDescription string

resource storageAccount 'Microsoft.Storage/storageAccounts@2025-01-01' existing = {
  name: storageAccountName

  resource blobServices 'blobServices' existing = {
    name: 'default'

    resource container 'containers' existing = {
      name: containerName
    }
  }
}

resource containerRoleAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(storageAccount::blobServices::container.id, principalId, roleDefinitionId)
  scope: storageAccount::blobServices::container
  properties: {
    principalId: principalId
    principalType: principalType
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', roleDefinitionId)
    description: roleDescription
  }
}

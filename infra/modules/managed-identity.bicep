// Thin wrapper over avm/res/managed-identity/user-assigned-identity.
// Instantiated once per identity (CMK, Function, Logic App) by main.bicep.
metadata name = 'managed-identity'
metadata description = 'Opinionated wrapper over AVM user-assigned-identity.'

@description('Managed identity resource name.')
param name string

@description('Azure region for the identity.')
param location string

@description('Common resource tags.')
param tags object

module identity 'br/public:avm/res/managed-identity/user-assigned-identity:0.6.0' = {
  name: take('id-${name}-deploy', 64)
  params: {
    name: name
    location: location
    tags: tags
  }
}

@description('Resource ID of the user-assigned identity.')
output resourceId string = identity.outputs.resourceId

@description('Principal (object) ID of the user-assigned identity.')
output principalId string = identity.outputs.principalId

@description('Client (application) ID of the user-assigned identity.')
output clientId string = identity.outputs.clientId

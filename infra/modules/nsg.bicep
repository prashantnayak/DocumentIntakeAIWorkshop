// Thin wrapper over avm/res/network/network-security-group.
// Instantiated once per subnet by main.bicep with a caller-supplied rule set
// so every subnet's required outbound egress is explicit and documented.
metadata name = 'nsg'
metadata description = 'Opinionated wrapper over AVM network-security-group with diagnostics to Log Analytics.'

@description('NSG resource name.')
param name string

@description('Azure region for the NSG.')
param location string

@description('Common resource tags.')
param tags object

@description('Security rules to apply. Each item follows the AVM securityRules[] schema (name, properties.{access, direction, priority, protocol, sourceAddressPrefix, sourcePortRange, destinationAddressPrefix, destinationPortRange}).')
param securityRules array

@description('Log Analytics workspace resource ID for NSG flow/diagnostic logs.')
param logAnalyticsWorkspaceResourceId string

module nsg 'br/public:avm/res/network/network-security-group:0.5.3' = {
  name: take('nsg-${name}-deploy', 64)
  params: {
    name: name
    location: location
    tags: tags
    securityRules: securityRules
    diagnosticSettings: [
      {
        name: 'diag-${name}'
        workspaceResourceId: logAnalyticsWorkspaceResourceId
        logCategoriesAndGroups: [
          { categoryGroup: 'allLogs' }
        ]
      }
    ]
  }
}

@description('Resource ID of the created NSG.')
output resourceId string = nsg.outputs.resourceId

@description('Name of the created NSG.')
output name string = nsg.outputs.name

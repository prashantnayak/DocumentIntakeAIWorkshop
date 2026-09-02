// Thin wrapper over avm/res/network/virtual-network.
// Creates the single VNet with three core subnets: Function integration,
// Logic App integration (both delegated to Microsoft.Web/serverFarms for
// regional VNet integration), and a private-endpoint subnet shared by every
// private data-plane service in the workload. An optional fourth subnet hosts
// the private workshop test VM.
metadata name = 'network'
metadata description = 'Opinionated wrapper over AVM virtual-network with delegated integration subnets and a private-endpoint subnet.'

import { networkConfigType } from '../types/shared-types.bicep'

@description('VNet resource name.')
param name string

@description('Azure region for the VNet.')
param location string

@description('Common resource tags.')
param tags object

@description('Address space and subnet CIDR configuration.')
param networkConfig networkConfigType

@description('Resource ID of the NSG protecting the Function integration subnet.')
param functionSubnetNsgResourceId string

@description('Resource ID of the NSG protecting the Logic App integration subnet.')
param logicAppSubnetNsgResourceId string

@description('Resource ID of the NSG protecting the private-endpoint subnet.')
param privateEndpointSubnetNsgResourceId string

@description('Whether to add the optional workshop test VM subnet.')
param enableTestAccess bool = false

@description('CIDR prefix for the optional workshop test VM subnet.')
param testVmSubnetPrefix string = '10.60.2.0/24'

@description('Resource ID of the NSG protecting the optional test VM subnet.')
param testVmSubnetNsgResourceId string = ''

@description('Log Analytics workspace resource ID for VNet diagnostics.')
param logAnalyticsWorkspaceResourceId string

var functionSubnetName = 'snet-func-integration'
var logicAppSubnetName = 'snet-logic-integration'
var privateEndpointSubnetName = 'snet-private-endpoints'
var testVmSubnetName = 'snet-test-vm'

module vnet 'br/public:avm/res/network/virtual-network:0.10.2' = {
  name: take('vnet-${name}-deploy', 64)
  params: {
    name: name
    location: location
    tags: tags
    addressPrefixes: [
      networkConfig.addressSpace
    ]
    diagnosticSettings: [
      {
        name: 'diag-${name}'
        workspaceResourceId: logAnalyticsWorkspaceResourceId
        logCategoriesAndGroups: [
          { categoryGroup: 'allLogs' }
        ]
        metricCategories: [
          { category: 'AllMetrics' }
        ]
      }
    ]
    subnets: concat(
      [
        {
          name: functionSubnetName
          addressPrefix: networkConfig.functionIntegrationSubnetPrefix
          networkSecurityGroupResourceId: functionSubnetNsgResourceId
          delegation: 'Microsoft.Web/serverFarms'
          privateEndpointNetworkPolicies: 'Enabled'
          privateLinkServiceNetworkPolicies: 'Enabled'
        }
        {
          name: logicAppSubnetName
          addressPrefix: networkConfig.logicAppIntegrationSubnetPrefix
          networkSecurityGroupResourceId: logicAppSubnetNsgResourceId
          delegation: 'Microsoft.Web/serverFarms'
          privateEndpointNetworkPolicies: 'Enabled'
          privateLinkServiceNetworkPolicies: 'Enabled'
        }
        {
          name: privateEndpointSubnetName
          addressPrefix: networkConfig.privateEndpointSubnetPrefix
          networkSecurityGroupResourceId: privateEndpointSubnetNsgResourceId
          privateEndpointNetworkPolicies: 'Disabled'
          privateLinkServiceNetworkPolicies: 'Enabled'
        }
      ],
      enableTestAccess
        ? [
            {
              name: testVmSubnetName
              addressPrefix: testVmSubnetPrefix
              networkSecurityGroupResourceId: testVmSubnetNsgResourceId
              defaultOutboundAccess: true
              privateEndpointNetworkPolicies: 'Enabled'
              privateLinkServiceNetworkPolicies: 'Enabled'
            }
          ]
        : []
    )
  }
}

@description('Resource ID of the VNet.')
output resourceId string = vnet.outputs.resourceId

@description('Resource ID of the Function App delegated integration subnet.')
output functionSubnetResourceId string = '${vnet.outputs.resourceId}/subnets/${functionSubnetName}'

@description('Resource ID of the Logic App delegated integration subnet.')
output logicAppSubnetResourceId string = '${vnet.outputs.resourceId}/subnets/${logicAppSubnetName}'

@description('Resource ID of the shared private-endpoint subnet.')
output privateEndpointSubnetResourceId string = '${vnet.outputs.resourceId}/subnets/${privateEndpointSubnetName}'

@description('Resource ID of the optional workshop test VM subnet, or empty when disabled.')
output testVmSubnetResourceId string = enableTestAccess ? '${vnet.outputs.resourceId}/subnets/${testVmSubnetName}' : ''

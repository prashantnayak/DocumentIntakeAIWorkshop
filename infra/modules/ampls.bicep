// Thin wrapper over avm/res/insights/private-link-scope (AMPLS).
// Provides a single private endpoint through which the Log Analytics
// workspace and Application Insights component are reachable, per Microsoft
// guidance to use exactly one AMPLS per DNS zone.
metadata name = 'ampls'
metadata description = 'Opinionated wrapper over AVM insights/private-link-scope: private-only access to Log Analytics + Application Insights.'

@description('AMPLS resource name.')
param name string

@description('Azure region for the resource.')
param location string

@description('Common resource tags.')
param tags object

@description('Resource ID of the Log Analytics workspace to scope.')
param logAnalyticsWorkspaceResourceId string

@description('Resource ID of the Application Insights component to scope.')
param appInsightsResourceId string

@description('Resource ID of the private-endpoint subnet.')
param privateEndpointSubnetResourceId string

@description('Resource IDs of the Azure Monitor private DNS zones, keyed by zone purpose (monitor, oms, ods, agentsvc).')
param privateDnsZoneResourceIdsByZone object

module ampls 'br/public:avm/res/insights/private-link-scope:0.7.3' = {
  name: take('ampls-${name}-deploy', 64)
  params: {
    name: name
    tags: tags
    accessModeSettings: {
      ingestionAccessMode: 'PrivateOnly'
      queryAccessMode: 'PrivateOnly'
    }
    scopedResources: [
      {
        name: 'law-scope'
        linkedResourceId: logAnalyticsWorkspaceResourceId
      }
      {
        name: 'appi-scope'
        linkedResourceId: appInsightsResourceId
      }
    ]
    privateEndpoints: [
      {
        name: 'pe-${name}'
        location: location
        subnetResourceId: privateEndpointSubnetResourceId
        privateDnsZoneGroup: {
          privateDnsZoneGroupConfigs: [
            { privateDnsZoneResourceId: privateDnsZoneResourceIdsByZone.monitor }
            { privateDnsZoneResourceId: privateDnsZoneResourceIdsByZone.oms }
            { privateDnsZoneResourceId: privateDnsZoneResourceIdsByZone.ods }
            { privateDnsZoneResourceId: privateDnsZoneResourceIdsByZone.agentsvc }
          ]
        }
      }
    ]
  }
}

@description('Resource ID of the AMPLS.')
output resourceId string = ampls.outputs.resourceId

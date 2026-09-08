// Thin wrapper over avm/res/network/private-dns-zone.
// Deploys every private DNS zone the workload needs and links each one to
// the workload VNet in a single pass.
metadata name = 'private-dns'
metadata description = 'Opinionated wrapper that deploys and VNet-links every required private DNS zone.'

@description('Fully-qualified private DNS zone names to create, e.g. privatelink.blob.core.windows.net.')
param zoneNames array

@description('Common resource tags.')
param tags object

@description('Resource ID of the VNet to link every zone to.')
param virtualNetworkResourceId string

module zones 'br/public:avm/res/network/private-dns-zone:0.8.1' = [
  for (zoneName, i) in zoneNames: {
    name: take('pdz-${i}-deploy', 64)
    params: {
      name: zoneName
      tags: tags
      virtualNetworkLinks: [
        {
          virtualNetworkResourceId: virtualNetworkResourceId
          registrationEnabled: false
        }
      ]
    }
  }
]

@description('Zone name/resource-ID pairs, kept as an array rather than an object map because Bicep does not allow a variable for-body to read module outputs. Callers should build a lookup map with toObject(zoneEntries, e => e.key, e => e.value).')
output zoneEntries array = [
  for (zoneName, i) in zoneNames: {
    key: zoneName
    value: zones[i].outputs.resourceId
  }
]

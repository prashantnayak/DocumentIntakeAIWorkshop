// Thin wrapper over avm/res/insights/action-group.
metadata name = 'action-group'
metadata description = 'Opinionated wrapper over AVM insights/action-group for routing alerts to operations email and an optional webhook.'

import { alertingConfigType } from '../types/shared-types.bicep'

@description('Action group resource name.')
param name string

@description('Common resource tags.')
param tags object

@description('Alerting receiver configuration.')
param alerting alertingConfigType

module actionGroup 'br/public:avm/res/insights/action-group:0.8.0' = {
  name: take('ag-${name}-deploy', 64)
  params: {
    name: name
    tags: tags
    groupShortName: take(name, 12)
    enabled: true
    emailReceivers: [
      {
        name: 'ops-email'
        emailAddress: alerting.operationsEmail
        useCommonAlertSchema: true
      }
    ]
    webhookReceivers: empty(alerting.webhookUri) ? [] : [
      {
        name: 'ops-webhook'
        serviceUri: alerting.webhookUri
        useCommonAlertSchema: true
      }
    ]
  }
}

@description('Resource ID of the action group.')
output resourceId string = actionGroup.outputs.resourceId

@description('Name of the action group.')
output name string = actionGroup.outputs.name

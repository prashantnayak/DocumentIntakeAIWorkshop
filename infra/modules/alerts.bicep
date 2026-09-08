// Alert rules for Blob-trigger poison messages, Durable/Function failures,
// Logic App failures, stale processing items, AI throttling, review SLA
// breach, and Key Vault access anomalies -- all routed to the
// shared action group. Metric-based signals use avm/res/insights/metric-alert;
// log-based signals use avm/res/insights/scheduled-query-rule.
metadata name = 'alerts'
metadata description = 'Poison queue, Durable/Function failure, Logic App failure, stale processing, Document Intelligence throttling, review SLA, and Key Vault anomaly alerts.'

@description('Common resource tags.')
param tags object

@description('Azure region for the alert rule resources (scheduled-query-rule/metric-alert are regional in newer API versions).')
param location string

@description('Resource ID of the action group every alert notifies.')
param actionGroupResourceId string

@description('Resource ID of the runtime storage account that hosts the Blob-trigger poison queue.')
param runtimeStorageAccountResourceId string

@description('Resource ID of the Document Intelligence (Cognitive Services) account.')
param documentIntelligenceResourceId string

@description('Resource ID of the Log Analytics workspace backing the workspace-based Application Insights instance, used as the query scope for log-based alerts.')
param logAnalyticsWorkspaceResourceId string

@minValue(0)
@maxValue(4)
@description('Severity for dead-letter / failure / throttling alerts (0=critical .. 4=verbose).')
param criticalSeverity int

@minValue(0)
@maxValue(4)
@description('Severity for the review SLA escalation alert.')
param slaSeverity int

@minValue(1)
@maxValue(100)
@description('Number of failed Key Vault data-plane operations within the evaluation window that is treated as an anomaly.')
param keyVaultAnomalyThreshold int

module poisonQueueAlert 'br/public:avm/res/insights/scheduled-query-rule:0.6.0' = {
  name: take('alert-blob-poison-deploy', 64)
  params: {
    name: 'alert-blob-trigger-poison'
    location: location
    tags: tags
    alertDescription: 'Fires when the Python Blob trigger places one or more repeatedly failed notifications in its runtime-storage poison queue.'
    kind: 'LogAlert'
    severity: criticalSeverity
    enabled: true
    skipQueryValidation: true
    scopes: [
      logAnalyticsWorkspaceResourceId
    ]
    windowSize: 'PT15M'
    evaluationFrequency: 'PT5M'
    autoMitigate: true
    criterias: {
      allOf: [
        {
          query: 'StorageQueueLogs | where _ResourceId =~ "${runtimeStorageAccountResourceId}/queueServices/default" | where OperationName =~ "PutMessage" and Uri has "/webjobs-blobtrigger-poison/"'
          timeAggregation: 'Count'
          operator: 'GreaterThan'
          threshold: 0
          failingPeriods: {
            numberOfEvaluationPeriods: 1
            minFailingPeriodsToAlert: 1
          }
        }
      ]
    }
    actions: {
      actionGroupResourceIds: [
        actionGroupResourceId
      ]
    }
  }
}

module functionFailureAlert 'br/public:avm/res/insights/scheduled-query-rule:0.6.0' = {
  name: take('alert-func-failures-deploy', 64)
  params: {
    name: 'alert-func-failure-rate'
    location: location
    tags: tags
    alertDescription: 'Fires when the Python Function App records a failed request, activity, or Durable orchestration in the evaluation window.'
    kind: 'LogAlert'
    severity: criticalSeverity
    enabled: true
    skipQueryValidation: true
    scopes: [
      logAnalyticsWorkspaceResourceId
    ]
    windowSize: 'PT15M'
    evaluationFrequency: 'PT5M'
    autoMitigate: true
    criterias: {
      allOf: [
        {
          query: 'union AppRequests, AppTraces | where (isnotempty(Success) and Success == false) or Message has_any ("DurableTaskFailure", "OrchestrationFailed", "ActivityFailed")'
          timeAggregation: 'Count'
          operator: 'GreaterThan'
          threshold: 0
          failingPeriods: {
            numberOfEvaluationPeriods: 1
            minFailingPeriodsToAlert: 1
          }
        }
      ]
    }
    actions: {
      actionGroupResourceIds: [
        actionGroupResourceId
      ]
    }
  }
}

module logicAppFailureAlert 'br/public:avm/res/insights/scheduled-query-rule:0.6.0' = {
    name: take('alert-logic-failures-deploy', 64)
    params: {
      name: 'alert-logic-workflow-failures'
      location: location
      tags: tags
      alertDescription: 'Fires when a business-rules, human-approval, or SLA Logic App workflow run fails.'
      kind: 'LogAlert'
      severity: criticalSeverity
      enabled: true
      skipQueryValidation: true
      scopes: [
        logAnalyticsWorkspaceResourceId
      ]
      windowSize: 'PT15M'
      evaluationFrequency: 'PT5M'
      autoMitigate: true
      criterias: {
        allOf: [
          {
            query: 'LogicAppWorkflowRuntime | where WorkflowName in ("business-rules-workflow", "human-approval-workflow", "sla-notification-workflow") | where Status == "Failed"'
            timeAggregation: 'Count'
            operator: 'GreaterThan'
            threshold: 0
            failingPeriods: {
              numberOfEvaluationPeriods: 1
              minFailingPeriodsToAlert: 1
            }
          }
        ]
      }
      actions: {
        actionGroupResourceIds: [
          actionGroupResourceId
        ]
      }
    }
  }

module staleProcessingAlert 'br/public:avm/res/insights/scheduled-query-rule:0.6.0' = {
    name: take('alert-stale-processing-deploy', 64)
    params: {
      name: 'alert-stale-processing-inbox'
      location: location
      tags: tags
      alertDescription: 'Fires when reconciliation finds a stranded nonterminal ProcessingInbox item.'
      kind: 'LogAlert'
      severity: criticalSeverity
      enabled: true
      skipQueryValidation: true
      scopes: [
        logAnalyticsWorkspaceResourceId
      ]
      windowSize: 'PT30M'
      evaluationFrequency: 'PT15M'
      autoMitigate: true
      criterias: {
        allOf: [
          {
            query: 'AppTraces | where Message has "ProcessingInboxStaleItem"'
            timeAggregation: 'Count'
            operator: 'GreaterThan'
            threshold: 0
            failingPeriods: {
              numberOfEvaluationPeriods: 1
              minFailingPeriodsToAlert: 1
            }
          }
        ]
      }
      actions: {
        actionGroupResourceIds: [
          actionGroupResourceId
        ]
      }
    }
  }
module aiThrottlingAlert 'br/public:avm/res/insights/metric-alert:0.4.1' = {
  name: take('alert-ai-throttle-deploy', 64)
  params: {
    name: 'alert-doc-intel-throttling'
    location: 'global'
    tags: tags
    alertDescription: 'Fires when Document Intelligence reports one or more blocked (throttled/quota-exceeded) calls.'
    severity: criticalSeverity
    enabled: true
    scopes: [
      documentIntelligenceResourceId
    ]
    windowSize: 'PT5M'
    evaluationFrequency: 'PT5M'
    targetResourceType: 'Microsoft.CognitiveServices/accounts'
    criteria: {
      'odata.type': 'Microsoft.Azure.Monitor.SingleResourceMultipleMetricCriteria'
      allof: [
        {
          criterionType: 'StaticThresholdCriterion'
          name: 'BlockedCallsPresent'
          metricName: 'BlockedCalls'
          metricNamespace: 'Microsoft.CognitiveServices/accounts'
          operator: 'GreaterThan'
          threshold: 0
          timeAggregation: 'Total'
        }
      ]
    }
    actions: [
      {
        actionGroupId: actionGroupResourceId
      }
    ]
  }
}

module reviewSlaAlert 'br/public:avm/res/insights/scheduled-query-rule:0.6.0' = {
  name: take('alert-review-sla-deploy', 64)
  params: {
    name: 'alert-review-sla-escalation'
    location: location
    tags: tags
    alertDescription: 'Fires whenever the sla-notification-workflow escalates an un-actioned review item to the supervisor group.'
    kind: 'LogAlert'
    severity: slaSeverity
    enabled: true
    scopes: [
      logAnalyticsWorkspaceResourceId
    ]
    windowSize: 'PT15M'
    evaluationFrequency: 'PT15M'
    autoMitigate: true
    criterias: {
      allOf: [
        {
          query: 'LogicAppWorkflowRuntime | where WorkflowName == "sla-notification-workflow" | where ActionName == "Send_escalation_email" | where Status == "Succeeded"'
          timeAggregation: 'Count'
          operator: 'GreaterThan'
          threshold: 0
          failingPeriods: {
            numberOfEvaluationPeriods: 1
            minFailingPeriodsToAlert: 1
          }
        }
      ]
    }
    actions: {
      actionGroupResourceIds: [
        actionGroupResourceId
      ]
    }
  }
}

module keyVaultAnomalyAlert 'br/public:avm/res/insights/scheduled-query-rule:0.6.0' = {
  name: take('alert-kv-anomaly-deploy', 64)
  params: {
    name: 'alert-kv-access-anomaly'
    location: location
    tags: tags
    alertDescription: 'Fires when Key Vault records an unusual number of non-successful data-plane operations (unauthorized/forbidden access attempts).'
    kind: 'LogAlert'
    severity: criticalSeverity
    enabled: true
    skipQueryValidation: true
    scopes: [
      logAnalyticsWorkspaceResourceId
    ]
    windowSize: 'PT15M'
    evaluationFrequency: 'PT15M'
    autoMitigate: true
    criterias: {
      allOf: [
        {
          query: 'AKVAuditLogs | where ResultType !in ("Success")'
          timeAggregation: 'Count'
          operator: 'GreaterThanOrEqual'
          threshold: keyVaultAnomalyThreshold
          failingPeriods: {
            numberOfEvaluationPeriods: 1
            minFailingPeriodsToAlert: 1
          }
        }
      ]
    }
    actions: {
      actionGroupResourceIds: [
        actionGroupResourceId
      ]
    }
  }
}

@description('Resource IDs of every alert rule created, for output/documentation purposes.')
output alertResourceIds array = [
  poisonQueueAlert.outputs.resourceId
  functionFailureAlert.outputs.resourceId
  logicAppFailureAlert.outputs.resourceId
  staleProcessingAlert.outputs.resourceId
  aiThrottlingAlert.outputs.resourceId
  reviewSlaAlert.outputs.resourceId
  keyVaultAnomalyAlert.outputs.resourceId
]

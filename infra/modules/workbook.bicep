// Raw ARM resource: Microsoft.Insights/workbooks.
// No AVM module exists for Azure Monitor Workbooks (confirmed absent from
// the avm/res/insights directory listing and the AVM module CSV index), so
// this is a deliberate, documented exception to the "prefer AVM" rule.
metadata name = 'workbook'
metadata description = 'RAW ARM (no AVM module exists for Microsoft.Insights/workbooks): operational workbook summarizing intake volume, auto-approve rate, review backlog, and failure counts.'

@description('Workbook display name.')
param displayName string

@description('Azure region for the workbook.')
param location string

@description('Common resource tags.')
param tags object

@description('Resource ID of the Log Analytics workspace the workbook queries.')
param logAnalyticsWorkspaceResourceId string

@description('Deterministic workbook resource name (must be a GUID).')
param workbookId string

var workbookContent = {
  version: 'Notebook/1.0'
  items: [
    {
      type: 1
      content: {
        json: '# Document Intake AI - Operations Workbook\r\nIntake volume, auto-approve rate, review backlog, and failure counts. No PHI is displayed here -- every query below aggregates non-PHI structured telemetry only.'
      }
      name: 'text-header'
    }
    {
      type: 3
      content: {
        version: 'KqlItem/1.0'
        query: 'AppRequests\r\n| where OperationName has "IngressProcessingFunction"\r\n| summarize IntakeCount = count() by bin(TimeGenerated, 1h)\r\n| order by TimeGenerated asc'
        size: 0
        queryType: 0
        resourceType: 'microsoft.operationalinsights/workspaces'
        visualization: 'linechart'
      }
      name: 'query-intake-volume'
    }
    {
      type: 3
      content: {
        version: 'KqlItem/1.0'
        query: 'LogicAppWorkflowRuntime\r\n| where WorkflowName == "business-rules-workflow"\r\n| where ActionName in ("Persist_auto_approved_document", "Forward_to_review_queue")\r\n| summarize Count = count() by ActionName, bin(TimeGenerated, 1h)\r\n| order by TimeGenerated asc'
        size: 0
        queryType: 0
        resourceType: 'microsoft.operationalinsights/workspaces'
        visualization: 'barchart'
      }
      name: 'query-auto-approve-rate'
    }
    {
      type: 3
      content: {
        version: 'KqlItem/1.0'
        query: 'LogicAppWorkflowRuntime\r\n| where WorkflowName == "human-approval-workflow"\r\n| where Status == "Running"\r\n| summarize ReviewBacklog = count()'
        size: 0
        queryType: 0
        resourceType: 'microsoft.operationalinsights/workspaces'
        visualization: 'tiles'
      }
      name: 'query-review-backlog'
    }
    {
      type: 3
      content: {
        version: 'KqlItem/1.0'
        query: 'AppExceptions\r\n| where OperationName has "IngressProcessingFunction"\r\n| summarize FailureCount = count() by bin(TimeGenerated, 1h), ProblemId\r\n| order by TimeGenerated asc'
        size: 0
        queryType: 0
        resourceType: 'microsoft.operationalinsights/workspaces'
        visualization: 'linechart'
      }
      name: 'query-failure-counts'
    }
  ]
  fallbackResourceIds: [
    logAnalyticsWorkspaceResourceId
  ]
}

resource workbook 'Microsoft.Insights/workbooks@2023-06-01' = {
  name: workbookId
  location: location
  tags: tags
  kind: 'shared'
  properties: {
    displayName: displayName
    serializedData: string(workbookContent)
    category: 'workbook'
    sourceId: logAnalyticsWorkspaceResourceId
  }
}

@description('Resource ID of the workbook.')
output resourceId string = workbook.id

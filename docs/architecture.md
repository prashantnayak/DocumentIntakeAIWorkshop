# Architecture

## Scope

The workshop deploys one private document-intake environment in Sweden Central,
resource group `rg-intakeai-dev-swc`. Intake is a timer-based Blob poller; there is
no event-delivery or broker tier.

## End-to-end sequence

| # | Flow | Implementation |
|---|---|---|
| 1 | A producer writes to `documents/incoming/` in private PHI storage. A future parallel migration may temporarily use an isolated prefix such as `incoming-v2`. | `infra/modules/storage-phi.bicep` |
| 2 | `PollIncomingDocuments` runs every minute, lists the configured prefix through the private Blob endpoint with the Function user-assigned identity, and isolates per-blob failures. It does not use the Blob trigger extension or a PHI queue; Durable state uses private `AzureWebJobsStorage`. | `src/functions/function_app.py`; `src/functions/intake/blob_service.py`; `infra/modules/function-app.bicep` |
| 3 | Registration resolves and records the exact blob version ID and ETag in `dbo.ProcessingInbox`. Repeated polls return the existing `DocumentId`. | `src/functions/intake/registration_service.py`; `sql/migrations/003_processing_state.sql` |
| 4 | A deterministic Durable instance receives only the `DocumentId`. An activity reloads the work item, downloads the registered version with an `IfNotModified` ETag condition, hashes it, and claims the hash atomically. | `DocumentOrchestrator`; `ProcessAndStage`; `blob_service.py`; `dbo.usp_ClaimDocumentHash` |
| 5 | Document Intelligence uses `prebuilt-layout` with key-value extraction and an optional custom classifier. With no classifier configured, deterministic routing derives a conservative result. | `document_service.py`; `routing.py`; `infra/modules/document-intelligence.bicep` |
| 6 | The Function writes the extracted workflow sidecar to the private PHI account and records its location and state in SQL. Durable history carries identifiers and states, not extracted content. | `processing_service.py`; `dbo.ProcessingInbox` |
| 7 | The Function sends only the document and sidecar references to the private, versioned Logic Apps Standard host. Its signed business-rules callback URL is rotated after workflow deployment into Key Vault and consumed through a versionless app-setting secret reference. | `workflow_service.py`; `.github/workflows/deploy.yml`; `logic-v2-*` |
| 8 | `business-rules-workflow` reads the sidecar, verifies the document identity, and authoritatively applies confidence, high-risk-type, and required-field rules. | `src/logicapps/business-rules-workflow/workflow.json` |
| 9a | Auto-approved metadata is inserted idempotently, the decision is appended, and the exact SAS-selected bytes are written to `processed/`. SQL then reaches `AutoApproved`. | `dbo.Documents`; `dbo.DecisionTrail`; HTTP and Blob built-ins |
| 9b | Review-required work reaches `ReviewPending`; the local `human-approval-workflow` claims an `ApprovalRun` lease and returns HTTP 202 before the long-running review completes. | `dbo.ProcessingInbox`; `dbo.WorkflowOperations` |
| 10 | Office 365 sends the approval email. The workflow waits durably for the callback and, in parallel, uses stateful `Wait` actions for reminder and escalation. The local SLA workflow rechecks SQL and claims separate operation leases before sending. | `human-approval-workflow`; `sla-notification-workflow` |
| 11 | Approval writes `dbo.Documents`, appends the reviewer identity, and writes the exact SAS-selected bytes to `processed/`; rejection records the decision and writes them to `failed/`. Optional approved-document archive uses Microsoft Graph and existing SharePoint Online. | Logic Apps HTTP/SQL/Blob/Office 365 connectors; opt-in Graph path |
| 12 | The Durable Function polls SQL using durable timers until terminal state, then `FinalizeSource` deletes the incoming blob only if its current version and ETag still equal the registered pair. A timer-triggered reconciler finds stale nonterminal rows and safely restarts absent or completed orchestrations. | `PollProcessingStatus`; `FinalizeSource`; `ReconcileStaleDocuments`; `dbo.usp_FindStaleProcessingItems` |

Polling failures are logged with safe error codes and retried by the next timer.
Rows registered before an interruption are recovered idempotently by the next
poll and by `ReconcileStaleDocuments`.

## Processing state and idempotency

`dbo.ProcessingInbox` is the cross-service source of truth. Its unique blob
identity and document-hash indexes prevent duplicate registration and duplicate
content processing. It records attempts, leases, state, failure code, and
sidecar reference.

`dbo.WorkflowOperations` provides recoverable leases for approval, reminder,
and escalation effects. An operation can be reclaimed only after its lease
expires; completed effects are not resent.

`dbo.DecisionTrail` remains append-only. `dbo.Documents` contains approved
business records and extracted values.

Durable orchestration history is not the source of truth and may be purged by
reconciliation before a deterministic instance ID is restarted.

## Business rules

| Rule | Workshop default | Configuration |
|---|---:|---|
| Confidence | `0.85` | `businessRules.confidenceThreshold` |
| Always-review document types | Consent Form; Advance Directive; Prior Authorization | `businessRules.highRiskDocumentTypes` |
| Required fields | PatientIdentifier; DateOfService; Provider | `businessRules.requiredFields` |
| Reminder | 24 hours | `businessRules.reviewReminderAfterHours` |
| Escalation | 72 hours | `businessRules.reviewEscalationAfterHours` |
| Reviewer link | 72 hours | `sasLinkExpiryHours` |

The Logic App is authoritative. Python computes the same candidate routing
signal to keep extraction deterministic, but the workflow makes the final
business decision.

## Compute and network

- Python 3.12 Durable Functions runs on a Linux Elastic Premium `EP1` plan with
  VNet integration, a private site endpoint, and public network access disabled.
- Logic Apps Standard runs on a private `WS1` host whose versioned resource name
  begins `logic-v2-`. Calls from the Function use the host's signed Request
  trigger callback over the private network.
- PHI storage, runtime storage, Key Vault, Document Intelligence, SQL, the
  Function, Logic App, and Azure Monitor ingestion use private endpoints and
  private DNS.
- Logic Apps allows required outbound access to the Office 365 managed connector
  runtime. Microsoft Graph egress is enabled only for the SharePoint opt-in.
- The optional Windows test VM has no public IP and is reached through Azure
  Bastion.

## Identity and secrets

| Identity | Use |
|---|---|
| Function user-assigned identity | Blob listing and exact-version access, Durable runtime bindings, Document Intelligence, SQL stored procedures, Key Vault secret resolution, deployment-package pull, and user-delegation SAS creation. |
| Logic App user-assigned identity | Host storage, SQL connector, and optional Graph calls. |
| Logic App system-assigned identity | Built-in Blob connector and Office 365 connection access policy. |
| CMK identity | Storage and SQL TDE keys; optional Document Intelligence second pass. |
| Deployment OIDC principal | Infrastructure deployment, package publication, and callback-secret rotation. |

No SQL login, storage account key, or application client secret is used by
application data-plane code. The signed callback URL is a secret and is never
printed. The hosting plans retain the documented Azure Files connection-string
exception required by their content shares.

## Reliability

- Blob version ID plus ETag prevents a later overwrite from changing the bytes
  selected by processing.
- SQL-backed idempotency and leases tolerate repeated polling and
  workflow retries.
- Durable timers avoid holding an execution thread during status polling or SLA
  waits.
- Polling, stale-inbox, Function/Durable failure, workflow failure,
  Document Intelligence throttling, SLA, and Key Vault alerts feed Azure
  Monitor.
- The reconciliation timer is a recovery path, not a second intake path.

## Workshop resilience exceptions

- Function `EP1` is not zone-redundant.
- SQL has 35-day point-in-time restore and no long-term retention.
- The test VM has encryption at host disabled.
- The environment is single-region and has no regional failover.

See [COMPLIANCE.md](COMPLIANCE.md) for consequences and
[runbook.md](runbook.md) for cutover and recovery.

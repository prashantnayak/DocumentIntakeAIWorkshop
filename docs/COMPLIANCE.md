# HIPAA Technical-Safeguard Mapping

> Infrastructure does not confer HIPAA compliance. A Microsoft BAA covering
> every used service, plus organizational administrative and physical
> safeguards, risk assessment, retention policy, incident response, and
> workforce controls remain customer responsibilities.

## Technical controls

| Safeguard | Workshop implementation |
|---|---|
| Unique identity | Entra-only SQL access, managed identities, Key Vault RBAC, deployment OIDC, and named reviewer/supervisor groups. |
| Least privilege | Function and Logic App identities receive service- and container-scoped access. No SQL login or application client secret is used. |
| Emergency access | The break-glass procedure in `docs/runbook.md` requires an authorized SQL administrator and an appended audit record. |
| Encryption at rest | PHI and runtime storage use customer-managed keys; SQL uses CMK-backed TDE. Document Intelligence uses Microsoft-managed encryption until its optional post-create CMK pass. |
| Field protection | PHI columns in `dbo.Documents` use Dynamic Data Masking. `sql/always-encrypted/` documents the opt-in client-side encryption path. |
| Transmission security | TLS 1.2+, private endpoints, private DNS, and VNet integration protect Blob, SQL, Key Vault, Document Intelligence, Function, Logic App, and monitoring paths. |
| Integrity | Intake records the immutable blob version ID and ETag; Python downloads that exact version with an ETag precondition, then SHA-256 hashes it. Blob versioning, soft delete, SQL unique indexes, and append-only decisions protect later processing. |
| Audit | Azure diagnostics, Application Insights, secured Logic Apps run history, `dbo.ProcessingInbox`, `dbo.WorkflowOperations`, and append-only `dbo.DecisionTrail`. Logs use identifiers and safe error codes, not extracted values. |
| Person authentication | Office 365 approval uses the reviewer's Entra-backed mailbox and records the returned user identity. Reviewer links are single-version, read-only, short-lived user-delegation SAS URLs reachable only on the private network. |
| Availability and recovery | Durable state, SQL inbox/leases, timer retries, reconciliation, ZRS storage, SQL point-in-time restore, and alerts. Workshop exceptions below limit production suitability. |

## Data minimization

- Durable history receives `DocumentId` and processing states, not document
  bytes or extracted fields.
- Python writes a private sidecar; the signed HTTP request carries references
  rather than the extracted payload.
- Workflow triggers and PHI-bearing actions use secure inputs and outputs.
- Approval email includes a document reference, classification, confidence, and
  missing field names. It does not include document content or field values.
- SharePoint archive is disabled by default and requires explicit Graph consent.
- The optional test VM and fixtures are synthetic-only.

## Secrets and authentication

The private Function calls the versioned Logic App Standard host through a
signed Request-trigger callback. Deployment stores the callback in Key Vault
under a versionless secret name; the Function uses a Key Vault app-setting
reference. The URL signature must be handled as a secret and never logged.

Application data access, Blob polling, Durable runtime access, SQL, Document
Intelligence, and optional Graph access use managed identity. The timer poller
lists the incoming prefix directly with the Blob SDK and the application
identity's container-scoped role. It requires neither a PHI queue nor
account-level management permission. The PHI account remains private and keyless.
The non-PHI
runtime account retains platform-required connection strings for the Azure
Files content shares and Logic Apps Standard host state. Logic Apps Standard's
workflow-state provider still parses `AzureWebJobsStorage` as a classic
connection string and does not start with identity-only host settings. These
values are generated during deployment and are not exposed as outputs. This
tenant's `StorageAccount_DisableLocalAuth_Modify` policy therefore requires a
time-bounded, resource-scoped exemption on the runtime account; the Python
Function still uses identity-based host storage, and the PHI storage account
remains keyless.

## Document Intelligence encryption

The account is created on `S0` with Microsoft-managed encryption because the
resource cannot enable a customer-managed key on its create request. The Key
Vault key and identity are prepared on the first deployment. Set
`enableDocumentIntelligenceCmk=true` and redeploy to complete the second pass,
then verify the deployment output before claiming CMK coverage.

## Governance

- HIPAA/HITRUST policy assignment is feature-flagged because its scope extends
  beyond this resource group.
- Defender for Cloud plans are feature-flagged and subscription-wide.
- SQL auditing, storage change feed, Key Vault audit logs, Function/Durable
  telemetry, Logic App workflow telemetry, polling failures, stale-inbox, SLA,
  and dependency alerts feed the central workspace.
- Production retention, legal hold, RPO/RTO, regional recovery, and reviewer
  access procedures require owner approval before real PHI is processed.

## Residency, continuity, and workshop exceptions

| Aspect | Workshop posture | Consequence |
|---|---|---|
| Region | Sweden Central only, `rg-intakeai-dev-swc` | No regional failover. |
| PHI storage | ZRS, versioning, soft delete | Zone protection, not regional disaster recovery. |
| Function plan | Linux `EP1`, not zone-redundant | Subscription lacks Sweden Central zone-redundant worker quota; raise quota and enable zones for production. |
| Logic App plan | Private `WS1`, one worker | Workshop capacity; size and resilience require production review. |
| Runtime extension egress | `AzureCloud` on TCP 443 | Azure Functions and Logic Apps Standard must download Microsoft extension bundles from `cdn.functions.azure.com`, which has no narrower NSG service tag. Use Azure Firewall FQDN rules for production. |
| SQL backup | 35-day point-in-time restore, no LTR | Does not meet multi-year backup retention; export/retention design is required for production. |
| Test VM | Encryption at host disabled | Subscription feature exception. Managed-disk encryption, Trusted Launch, Secure Boot, and vTPM remain enabled. Never use it for PHI. |
| Audit retention | Configured central retention | Must be reconciled with the customer's final medical-record and security-log policy. |

These exceptions are knowingly accepted for the workshop and are not a
production PHI authorization.

# SQL Schema and Processing State

Azure SQL is Entra-only. Run migrations in numeric order from a VNet-connected
machine:

```powershell
$token = (Get-AzAccessToken -ResourceUrl 'https://database.windows.net/').Token
Get-ChildItem .\sql\migrations\*.sql | Sort-Object Name | ForEach-Object {
    Invoke-Sqlcmd `
      -ServerInstance '<server>.database.windows.net' `
      -Database '<database>' `
      -InputFile $_.FullName `
      -AccessToken $token
}
```

`scripts/post-deploy.ps1` substitutes the deployed managed-identity and Entra
group names and object-ID SIDs while applying the same ordered set. Explicit
SIDs let migration 004 create external users without granting Microsoft Graph
directory permissions to the SQL logical server identity.

## Migrations

| # | File | Purpose |
|---|---|---|
| 001 | `001_initial_schema.sql` | `IdempotencyLedger`, append-only `DecisionTrail`, and approved `Documents`. |
| 002 | `002_ddm_masking.sql` | Dynamic Data Masking for PHI columns. |
| 003 | `003_processing_state.sql` | `ProcessingInbox`, `WorkflowOperations`, unique indexes, processing-state procedures, and recoverable leases. |
| 004 | `004_users_and_permissions.sql` | Contained Entra users and least-privilege grants for Function, Logic App, reviewers, and supervisors. |

## Tables

### `dbo.ProcessingInbox`

Cross-service source of truth for one exact Blob version. It stores:

- `DocumentId`;
- storage account, container, blob name, version ID, and ETag;
- SHA-256 hash and private workflow-sidecar location;
- processing state, failure code, attempts, lease, and timestamps.

The blob-version uniqueness constraint makes repeated trigger delivery return
the same work item. The filtered hash uniqueness constraint makes duplicate
content deterministic. Nonterminal rows are candidates for the reconciliation
timer; Durable history is not authoritative.

### `dbo.WorkflowOperations`

Recoverable side-effect leases keyed by `DocumentId` and operation type.
Approval, reminder, and escalation runs claim a lease before sending email.
Expired leases may be retried; sent/completed effects cannot be claimed again.

### `dbo.DecisionTrail`

Append-only audit entries for ingress, business rules, approval, and SLA
notifications. It contains identifiers, classification metadata, rule, outcome,
operator identity, timestamp, and non-PHI detail. Application principals receive
no update or delete grant.

### `dbo.Documents`

Approved business records, including extracted PHI values. Dynamic Data Masking
is the enforced field-level access control; TDE protects the database at rest.

### `dbo.IdempotencyLedger`

Retained compatibility ledger for document-hash decisions and audit continuity.
New orchestration recovery is driven by `ProcessingInbox`.

## State model

Expected progression:

```text
Registered -> Processing -> Analyzed/Ready -> Dispatched
                                      |        |
                                      |        +-> ReviewPending -> Approved | Rejected
                                      +-----------> AutoApproved

Any processing stage -> Duplicate | Failed
```

Use the exact check-constraint values and stored procedures in migration 003
when diagnosing the deployed schema. State transitions are conditional so a
retry cannot overwrite a later terminal decision.

## Least privilege

- Function identity executes registration, exact-work lookup, hash claim,
  state update/status, and stale-item procedures.
- Logic App user-assigned identity reads/writes approved records, decision
  entries, processing state, and workflow leases through the SQL connector.
- Reviewer and supervisor groups receive only approved-record and decision
  visibility required by the workshop.
- No SQL password or server login exists.

## Routine operations

```sql
SELECT TOP (50)
    DocumentId, BlobName, BlobVersionId, BlobETag, State,
    AttemptCount, FailureCode, UpdatedAtUtc
FROM dbo.ProcessingInbox
ORDER BY UpdatedAtUtc DESC;

SELECT TOP (50)
    DocumentId, OperationType, State, AttemptCount,
    LeaseExpiresAtUtc, LastErrorCode, UpdatedAtUtc
FROM dbo.WorkflowOperations
ORDER BY UpdatedAtUtc DESC;
```

Avoid selecting extracted PHI for health checks. See `docs/runbook.md` for
poison notification, reconciliation, and cutover procedures.

## Backup posture

The workshop configures 35-day point-in-time restore and no long-term retention.
This is an explicit cost exception and is not adequate for production medical
record retention.

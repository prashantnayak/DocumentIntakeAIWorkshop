# Operations Runbook

Environment: `rg-intakeai-dev-swc`, Sweden Central.

The custom `PhiStorage` trigger connection has no queue endpoint. Blob-trigger
checkpoints and `webjobs-blobtrigger-poison` are in private
`AzureWebJobsStorage`; use its Queue private endpoint from the test VM. The
Function identity has Storage Queue Data Contributor on that runtime account.

## Alert response

| Alert | First response |
|---|---|
| Blob-trigger poison queue | Inspect `webjobs-blobtrigger-poison` in the private runtime storage account from the test VM. Correlate the blob reference with `dbo.ProcessingInbox`; resolve the registration failure before replaying. Never copy PHI into a ticket or log. |
| Function or Durable failure | Check Application Insights for the safe error code and `DocumentId`, then verify private DNS, runtime storage, SQL, Key Vault, Blob, and Document Intelligence. |
| Stale processing item | Query `dbo.ProcessingInbox` for nonterminal rows and compare with Durable instance `document-<DocumentId>`. The reconciliation timer normally restarts a missing or completed instance. |
| Logic App failure | Locate the secured run by `DocumentId`. Check the callback secret reference, sidecar existence, SQL state, connector health, and `dbo.WorkflowOperations` lease. |
| Document Intelligence throttling | Check S0 usage and retry rate. Reduce Function concurrency or request quota if sustained. |
| Review SLA escalation | Verify the item is still `ReviewPending`, then check `ReviewReminder`/`ReviewEscalation` operation rows and Office 365 connector consent. |
| Key Vault anomaly | Review Key Vault audit logs and calling identity. Rotate the callback secret or affected key if compromise is suspected. |

## Inspect processing safely

From a VNet-connected host using Entra SQL authentication:

```sql
SELECT TOP (50)
    DocumentId, BlobName, BlobVersionId, BlobETag, State,
    AttemptCount, FailureCode, UpdatedAtUtc
FROM dbo.ProcessingInbox
ORDER BY UpdatedAtUtc DESC;

SELECT TOP (50)
    DocumentId, OperationType, State, AttemptCount,
    LeaseOwner, LeaseExpiresAtUtc, LastErrorCode, UpdatedAtUtc
FROM dbo.WorkflowOperations
ORDER BY UpdatedAtUtc DESC;

SELECT TOP (50)
    DocumentId, Stage, Outcome, RuleFired, ApproverIdentity, TimestampUtc
FROM dbo.DecisionTrail
ORDER BY TimestampUtc DESC;
```

Do not select `ExtractedFieldsJson` during routine diagnosis.

## Poison notification replay

1. Pause the producer for the affected blob name.
2. Inspect the poison message from the private test VM and identify the exact
   source blob; do not export its content.
3. Correct identity, private DNS, SQL, or registration configuration.
4. If the version already exists in `ProcessingInbox`, let reconciliation start
   its deterministic Durable instance. Otherwise, copy the exact source version
   to a new name under the active incoming prefix to create a fresh notification.
5. Confirm a terminal inbox state, then delete the poison notification.

Never overwrite the source to force retry: the registered version ID and ETag
must continue to identify the bytes originally accepted.

## Stale work and reconciliation

`ReconcileStaleDocuments` runs on `ReconciliationSchedule`. It reads stale
nonterminal rows, leaves active Durable instances alone, purges completed
history when necessary, and restarts the deterministic instance.

Manual recovery:

1. Verify the row is nonterminal and older than the configured stale threshold.
2. Verify no active Logic App run or unexpired `WorkflowOperations` lease owns
   the same effect.
3. Run the reconciliation Function or wait for its next schedule.
4. Do not directly change SQL state unless the incident procedure authorizes it;
   an incorrect state can duplicate approval email or blob movement.

## Logic App callback secret

The Function app setting resolves the versionless Key Vault secret
`logic-business-rules-callback`. The deployment workflow obtains a fresh signed
callback only after the versioned Logic App host and workflows are published.

If the host or trigger is replaced, rerun the callback-rotation deployment step,
restart the Function App, and run a synthetic canary. Never paste the URL into
logs, tickets, shell history, or source control.

## Reviewer document links

Approval email contains a read-only, HTTPS-only user-delegation SAS for one blob
version. The PHI account is private, so the link opens only from a
VNet-connected workstation. Default validity is 72 hours and must remain at
least the escalation interval. Email includes field names and classification
metadata, not extracted values or document content.

## Required post-deploy actions

1. Run `scripts/post-deploy.ps1` from inside the VNet to apply migrations
   `001`–`004` and create contained Entra users.
2. Authorize the versioned Office 365 connection interactively.
3. If SharePoint archive is enabled, run
   `scripts/grant-graph-permissions.ps1`.
4. Optionally enable the Document Intelligence CMK second pass.
5. Confirm the Key Vault callback secret exists without displaying its value.

## End-to-end test from the Windows VM

Deploy the optional, private test path:

```powershell
.\scripts\deploy-test-access.ps1 `
  -SubscriptionId <subscription-id> `
  -ParametersFile .\infra\params\dev.bicepparam
```

Connect through Azure portal **Bastion**. The VM has no public IP. Clone or copy
the repository's synthetic fixtures to the VM, sign in with `az login`, and use
Entra authentication:

```powershell
$prefix = 'incoming-v2' # use 'incoming' only after cutover
az storage blob upload `
  --auth-mode login `
  --account-name <phi-storage-account> `
  --container-name documents `
  --name "$prefix/sample-intake-document.pdf" `
  --file .\tests\fixtures\sample-intake-document.pdf `
  --overwrite false
```

Validate:

1. One `ProcessingInbox` row records a nonempty version ID and ETag.
2. Application Insights shows `DocumentBlobStarter`,
   `DocumentOrchestrator`, and activities without PHI.
3. The normal fixture reaches `AutoApproved`; the source leaves the incoming
   prefix and appears under `processed/`.
4. The missing-fields fixture reaches `ReviewPending`, creates one
   `ApprovalRun` lease, sends one approval, and starts durable reminder and
   escalation waits.
5. Approval reaches `Approved`; rejection reaches `Rejected` and moves to
   `failed/`. Reminder/escalation sends only while review remains pending.
6. Temporarily stopping an orchestration demonstrates that the reconciliation
   timer restarts it. Use a synthetic item only.
7. Runtime storage `webjobs-blobtrigger-poison` remains empty.

Never test with real PHI.

## Safe `incoming-v2` to `incoming` cutover

1. Keep the replacement at `incoming-v2` while both synthetic paths and
   recovery checks are validated.
2. Pause every producer.
3. Confirm the previous generation is drained, has no active runs, and cannot
   accept new `incoming/` work.
4. Change `functionIncomingPrefix` to `incoming`, deploy, restart, and sync
   Function triggers.
5. Upload a uniquely named synthetic canary to `incoming/`; verify exact-version
   registration and terminal state.
6. Resume producers.
7. Preserve validation evidence and resource names. Preview cleanup:

   ```powershell
   Get-Help .\scripts\remove-legacy-messaging.ps1 -Full
   .\scripts\remove-legacy-messaging.ps1 <exact legacy names and all gates> -WhatIf
   ```

8. Run the same command without `-WhatIf` only after explicitly supplying all
   four gates: intake paused, old work drained, no active old runs, and
   replacement smoke test passed.

The cleanup script is deliberately name-scoped and refuses to run without every
gate. Verify the replacement after cleanup before deleting deployment evidence.

## Key rotation

- Storage and SQL TDE keys follow Key Vault rotation policy.
- Document Intelligence uses Microsoft-managed encryption until its optional
  CMK second deployment is completed.
- The signed Logic App callback rotates whenever the versioned workflow host or
  Request trigger changes.
- Always Encrypted keys, when that opt-in is used, require the procedure in
  `sql/always-encrypted/README.md`.

## Break glass

An authorized member of the SQL admin group may inspect state and record a
manual decision in `dbo.DecisionTrail` when the approval connector is
unavailable. Record the operator identity, reason, time, and outcome. Do not
grant public network access or copy PHI outside the private boundary.

## Teardown

Delete `rg-intakeai-dev-swc` only after retention and evidence requirements are
met. Key Vault purge protection keeps its name reserved for the retention
window. SQL long-term retention is disabled; only the configured 35-day
point-in-time restore window applies before resource deletion.

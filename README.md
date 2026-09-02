# Document Intake AI Workshop

Private, identity-first document intake on Azure. A timer-based Blob poller starts a
Python Durable Functions orchestration, Azure AI Document Intelligence extracts
and classifies the exact registered blob version, Logic Apps Standard applies
business rules and human approval, and Azure SQL holds processing state and the
append-only decision trail.

## Deployed environment

| Setting | Value |
|---|---|
| Resource group | `rg-intakeai-dev-swc` |
| Region | Sweden Central (`swedencentral`) |
| Environment | One development/workshop environment, under 1,000 documents/day |
| Function runtime | Python 3.12 on Linux Elastic Premium `EP1` |
| Workflow runtime | Private, versioned Logic Apps Standard host (`logic-v2-*`) |
| Intake | Identity-based timer poller on `documents/<configured-prefix>/` |
| State | Azure SQL `dbo.ProcessingInbox`, `dbo.WorkflowOperations`, `dbo.DecisionTrail`, and `dbo.Documents` |

The design has no event-delivery service or message broker. `PollIncomingDocuments`
uses the Azure Blob SDK and the Function managed identity to list the private Blob
prefix directly every minute. It does not use the Blob trigger extension or a PHI
queue. Durable state remains in private `AzureWebJobsStorage`.

## Repository layout

| Path | Contents |
|---|---|
| `infra/` | Subscription-scoped Bicep and the Sweden Central dev parameters. |
| `src/functions/` | Python 3.12 Durable Functions app and intake services. |
| `src/logicapps/` | Stateful business-rules, approval, and SLA workflows. |
| `sql/` | Four ordered migrations, masking, permissions, and an Always Encrypted upgrade. |
| `scripts/` | Bootstrap, post-deploy, test-access, SharePoint opt-in, and migration cleanup scripts. |
| `docs/` | Architecture, decisions, compliance, operations, and diagrams. |
| `tests/` | Python unit tests, infrastructure tests, and synthetic PDFs. |

## How processing works

1. `PollIncomingDocuments` lists `documents/incoming/` every minute, using the
   Function managed identity.
2. The poller registers the storage account, container, blob name,
   immutable version ID, and ETag in `dbo.ProcessingInbox`. A deterministic
   Durable instance starts with only the `DocumentId`.
3. Activities download that exact version with an ETag precondition, hash it,
   deduplicate it, call Document Intelligence, and write a private sidecar blob.
4. The Function invokes the private `logic-v2-*` host through the signed HTTP
   callback URL stored as a versionless Key Vault secret. The Function setting
   uses a Key Vault reference; the signature is not committed or logged.
5. Logic Apps evaluates the authoritative rules, persists approved records, or
   starts human approval. Stateful waits provide the reminder and escalation
   delays. `dbo.WorkflowOperations` leases external side effects so retries do
   not send duplicate email.
6. The Durable orchestration polls SQL with durable timers until a terminal
   state. `ReconcileStaleDocuments` restarts stranded nonterminal work.

See [architecture](docs/architecture.md) and the
[operations runbook](docs/runbook.md).

## Prerequisites

- Azure CLI with Bicep, PowerShell 7, Python 3.12, and Pester 5.
- Subscription rights to create the resource group and required role
  assignments.
- Tenant-specific SQL admin, reviewer, and supervisor Entra groups.
- A VNet-connected self-hosted deployment runner, or equivalent workstation,
  that resolves the workload private DNS zones.
- Existing Office 365 and, when enabled, SharePoint Online services.

## Deploy

1. Bootstrap OIDC access:

   ```powershell
   .\scripts\bootstrap.ps1 `
     -SubscriptionId <subscription-id> `
     -ResourceGroupName rg-intakeai-dev-swc `
     -Location swedencentral `
     -GitHubOrg <org> `
     -GitHubRepo DocumentIntakeAIWorkshop `
     -GitHubEnvironment dev
   ```

2. Populate the `dev` GitHub environment values described by the deployment
   workflow, then run **Deploy**.
3. From the private deployment runner, the workflow publishes the Python and
   Logic App packages, obtains the business-rules trigger callback, writes it to
   Key Vault, restarts the Function, and synchronizes triggers.
4. From a VNet-connected machine, apply all SQL migrations:

   ```powershell
   .\scripts\post-deploy.ps1 <required parameters>
   ```

5. Authorize the Office 365 API connection interactively. If SharePoint archive
   is enabled, run `scripts/grant-graph-permissions.ps1`.
6. Optionally enable the Document Intelligence customer-managed-key second pass
   after its initial creation.

## Safe intake cutover

`infra/params/dev.bicepparam` now points the replacement trigger at `incoming`.
The Sweden Central environment has completed this cutover: the legacy
application Function, Logic App, Service Bus namespace, and Blob-to-Service-Bus
Event Grid subscription are removed. Defender for Storage's platform-managed
Event Grid subscription remains intentionally.
For a parallel migration in another environment, initially override it to
`incoming-v2`; never point two generations at `incoming/`.

1. Deploy the replacement stack with `functionIncomingPrefix='incoming-v2'`.
2. From the private test VM, upload both synthetic fixtures to
   `documents/incoming-v2/`. Verify terminal SQL state, blob movement, approval,
   SLA waits, polling-failure monitoring, and reconciliation.
3. Pause producers. Let all legacy work drain, confirm no active legacy runs,
   and retain evidence of the replacement smoke test.
4. Change `functionIncomingPrefix` to `incoming`, redeploy, synchronize Function
   triggers, then upload one final synthetic canary to `incoming/`.
5. Resume producers only after the canary reaches a terminal state.
6. Preview and then run `scripts/remove-legacy-messaging.ps1`. The script
   requires explicit `IntakePaused`, `QueuesDrained`, `NoActiveLegacyRuns`, and
   `ReplacementSmokeTestPassed` gates and deletes only the exact legacy resource
   names supplied by the operator:

   ```powershell
   Get-Help .\scripts\remove-legacy-messaging.ps1 -Full
   .\scripts\remove-legacy-messaging.ps1 <exact legacy names and all gates> -WhatIf
   .\scripts\remove-legacy-messaging.ps1 <exact legacy names and all gates>
   ```

Rollback before cleanup by pausing producers, restoring the replacement prefix
to `incoming-v2`, and reactivating the prior generation. After cleanup, rollback
requires redeploying that generation from retained deployment records.

## Test from the private Windows VM

The optional VM has no public IP and is reached through Azure Bastion. Deploy it
only for synthetic testing:

```powershell
.\scripts\deploy-test-access.ps1 `
  -SubscriptionId <subscription-id> `
  -ParametersFile .\infra\params\dev.bicepparam
```

On the VM, sign in with Azure CLI and upload using Entra authentication:

```powershell
az storage blob upload `
  --auth-mode login `
  --account-name <phi-storage-account> `
  --container-name documents `
  --name incoming/sample-intake-document.pdf `
  --file .\tests\fixtures\sample-intake-document.pdf
```

Use the missing-fields fixture for the approval path. Query
`dbo.ProcessingInbox`, `dbo.WorkflowOperations`, and `dbo.DecisionTrail`, and
confirm the source moves to `processed/` or `failed/`. Full checks are in
[the runbook](docs/runbook.md). Never place real PHI on this VM.

## Validation

```powershell
az bicep build --file infra\main.bicep --outfile infra\main.json
az bicep build-params --file infra\params\dev.bicepparam --outfile infra\params\dev.parameters.json
.\scripts\verify-avm-module-versions.ps1
python -m pip install -r src\functions\requirements-dev.txt
python -m pytest tests\functions
Get-ChildItem src\logicapps -Recurse -Filter *.json |
  ForEach-Object { Get-Content -Raw $_.FullName | ConvertFrom-Json | Out-Null }
Invoke-Pester -Path tests\ps-rule\ps-rule.tests.ps1 -Output Detailed
```

## Workshop exceptions

- The Function `EP1` plan is not zone-redundant because the subscription has no
  Sweden Central quota for zone-redundant workers.
- SQL keeps 35 days of point-in-time restore backups and has no long-term
  retention.
- The optional test VM has encryption at host disabled; managed-disk encryption,
  Trusted Launch, Secure Boot, and vTPM remain enabled.

These are workshop-only exceptions, not a production PHI posture. See
[COMPLIANCE.md](docs/COMPLIANCE.md).

## License

See `LICENSE`.

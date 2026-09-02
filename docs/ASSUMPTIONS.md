# Architecture Decisions and Assumptions

This file records the current deployment contract, not superseded designs.

## Fixed decisions

- One workshop environment is deployed to Sweden Central in
  `rg-intakeai-dev-swc`, at fewer than 1,000 documents per day.
- PHI storage uses one private `documents` container with `incoming/`,
  `processed/`, `failed/`, and private workflow-sidecar prefixes.
- Intake is an identity-based timer poller. It uses the Blob SDK and the
  Function application identity to list the private incoming prefix directly.
  It does not use the Blob trigger extension or a PHI queue. Durable state uses
  private `AzureWebJobsStorage`.
- The Function is Python 3.12 Durable Functions on Linux Elastic Premium `EP1`.
- SQL `ProcessingInbox` is the cross-service processing source of truth.
  Durable history contains only identifiers and state.
- The registered blob version ID and ETag define the input. Processing must not
  silently switch to a newer version with the same name.
- The Function invokes a Request trigger on a private, versioned Logic Apps
  Standard host. The signed callback URL is a Key Vault secret reference.
- Logic Apps owns authoritative rules, Office 365 human approval, durable SLA
  waits, final persistence, and blob disposition.
- `WorkflowOperations` leases approval/reminder/escalation effects across
  retries.
- The Function reconciliation timer restarts stale nonterminal work.
- Document Intelligence, Azure SQL, Office 365, and SharePoint Online are
  existing approved dependencies. SharePoint archive is opt-in.
- The optional Windows VM has no public IP and is accessed through Azure
  Bastion. It is synthetic-test-only.

## Identity split

| Principal | Responsibility |
|---|---|
| Function user-assigned identity | Blob source/runtime access, SQL procedures, Document Intelligence, Key Vault reference resolution, package pull, and reviewer SAS creation. |
| Logic App user-assigned identity | Host storage, SQL connector, optional Microsoft Graph. |
| Logic App system-assigned identity | Workflow Blob connector and Office 365 API-connection policy. |
| CMK identity | Storage and SQL keys; optional Document Intelligence key. |
| Deployment OIDC principal | Bicep deployment, private package publication, and signed callback rotation. |

The Logic App system identity exists only after the site is created, so
post-site Blob and API-connection permissions are deployed afterward.

## Business-rule ownership

The Python extraction path calculates a candidate outcome for deterministic
staging. `business-rules-workflow` is authoritative and re-evaluates:

1. confidence below `0.85`;
2. exact membership in the high-risk document-type list; and
3. any missing required field.

Any gate sends the item to human review. Duplicate content and unreadable
results remain Function concerns because they are resolved before dispatch.

## Review behavior

- The approval workflow claims `ApprovalRun`, records `PendingReview`, and
  returns HTTP 202 before waiting for the reviewer.
- Reminder and escalation use stateful Logic App waits, then invoke the local
  SLA workflow.
- The SLA workflow checks that SQL still says `ReviewPending` and claims a
  distinct operation lease before sending.
- Office 365 approval provides responder identity but no free-text comment
  contract; do not claim reviewer comments are captured.
- Reviewer URLs are read-only, exact-version SAS links reachable only through
  the private storage endpoint. Link duration must be at least the escalation
  interval.

## Deployment and cutover assumptions

- Application packages are published from a VNet-connected runner because the
  runtime storage and Logic App SCM endpoint are private.
- The deploy job publishes the versioned Logic App host first, rotates its
  signed business-rules callback into Key Vault, then activates and synchronizes
  the Python Function.
- `functionIncomingPrefix` remains `incoming-v2` for parallel validation.
  Producers are paused before switching it to `incoming`; only one generation
  may own `incoming/`.
- Legacy cleanup occurs only after drain, no-active-run, and replacement-canary
  evidence. `scripts/remove-legacy-messaging.ps1` enforces these gates and exact
  resource names.

## Workshop exceptions

- Function `EP1` is not zone-redundant because the subscription has no
  Sweden Central quota for zone-redundant App Service workers.
- SQL uses 35-day point-in-time restore and no long-term retention.
- The test VM has encryption at host disabled; managed-disk encryption and
  Trusted Launch controls remain on.
- Single-region deployment has no regional disaster recovery.

## Inputs still owned by the deployer

- Subscription and tenant IDs; GitHub OIDC repository/environment.
- SQL administrator, reviewer, and supervisor Entra group IDs and email
  addresses.
- Alert receivers, tags, cost owner, and operational on-call ownership.
- Trained custom classifier model ID, if one exists.
- Office 365 interactive connection consent.
- SharePoint site, drive, folder, and Graph consent when archive is enabled.
- BAA coverage, retention/legal-hold policy, RPO/RTO, and production approval.
- Whether and when to enable the Document Intelligence CMK second pass,
  policy assignment, Defender plans, and optional immutability.

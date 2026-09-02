# Architecture Diagram

The deployable architecture is shown below. The editable
`SwedenCentralDeployment.excalidraw`, its PNG export, and this Mermaid view
show the same Python Durable design.

```mermaid
flowchart TB
    Producer[Document producer] -->|write to active prefix| Phi[(Private PHI Blob Storage<br/>documents/incoming-v2 during validation<br/>documents/incoming after cutover)]

    subgraph PrivateAzure["Sweden Central · rg-intakeai-dev-swc · private network"]
        Phi -->|identity-based polling trigger| Starter[DocumentBlobStarter<br/>Python 3.12]
        Starter -->|version ID + ETag| Inbox[(Azure SQL<br/>ProcessingInbox)]
        Starter --> Durable[Durable Functions<br/>DocumentOrchestrator · Linux EP1]

        Durable --> Process[ProcessAndStage activity]
        Process -->|exact version + ETag condition| Phi
        Process -->|extract and classify| DI[Azure AI<br/>Document Intelligence]
        Process -->|hash, state, sidecar reference| Inbox
        Process -->|private sidecar| Phi

        Durable -->|signed private HTTP<br/>document + sidecar references| Rules[Logic Apps Standard v2<br/>business-rules-workflow]
        KV[Key Vault<br/>callback URL secret reference] --> Durable
        Rules -->|authoritative rules| Auto{Outcome}

        Auto -->|persist auto approval| Records[(Azure SQL<br/>Documents + DecisionTrail)]
        Auto -->|move approved blob| Processed[Blob<br/>processed/]
        Auto -->|review| Approval[human-approval-workflow<br/>stateful]
        Approval --> Ops[(Azure SQL<br/>WorkflowOperations leases)]
        Approval -->|approval email| O365[Existing Office 365]
        Approval -->|durable wait 24h / 72h| SLA[sla-notification-workflow]
        SLA -->|reminder / escalation| O365
        SLA --> Ops
        Approval -->|persist decision| Records
        Approval -->|approved| Processed
        Approval -->|rejected| Failed[Blob<br/>failed/]
        Approval -. opt-in Graph archive .-> SP[Existing SharePoint Online]

        Durable -->|durable SQL status polling| Inbox
        Durable -->|FinalizeSource<br/>delete only matching version + ETag| Phi
        Reconcile[Reconciliation timer] -->|restart stale nonterminal item| Durable
        Poison[(Runtime storage<br/>webjobs-blobtrigger-poison)] -. repeated trigger failure .- Starter

        Monitor[Azure Monitor<br/>Log Analytics + App Insights + alerts] --- Durable
        Monitor --- Rules
        Monitor --- Inbox
    end

    VM[Optional Windows test VM] -->|Azure Bastion; synthetic fixtures only| Phi
```

Key properties:

- The Function reads the exact registered blob version under its ETag
  precondition.
- SQL is the durable cross-service state and side-effect lease store.
- The Logic App callback signature is held in Key Vault, not configuration
  source.
- Approval reminder and escalation are durable Logic Apps waits.
- SharePoint and the Bastion-accessed test VM are optional.

See [architecture.md](../architecture.md) for the sequence and
[runbook.md](../runbook.md) for cutover and recovery.

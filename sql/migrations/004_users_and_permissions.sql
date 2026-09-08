-- =============================================================================
-- Migration 004: Contained database users and least-privilege grants.
-- =============================================================================
-- Entra-only authentication means every principal below is a contained
-- database user mapped to a Microsoft Entra identity -- there is no SQL login or
-- password anywhere in this repository. Run this AFTER the managed identities
-- exist (infra deploy) and BEFORE first pipeline execution, connected as a
-- member of the Entra SQL admin group (entraGroups.sqlAdminGroupObjectId in
-- infra/params/*.bicepparam). scripts/post-deploy.ps1 automates this step by
-- substituting the real identity/group names and object-ID SIDs for an
-- environment. Explicit SIDs avoid requiring the SQL logical server identity
-- to query Microsoft Graph during CREATE USER. Azure SQL maps managed identities
-- and applications by client/application ID; groups map by object ID.
--
-- TYPE E identifies external users/service principals (including managed
-- identities); TYPE X identifies external groups.
-- =============================================================================

IF DATABASE_PRINCIPAL_ID(N'<function-app-identity-name>') IS NULL
    CREATE USER [<function-app-identity-name>] WITH SID = <function-app-identity-sid>, TYPE = E;
GO

IF DATABASE_PRINCIPAL_ID(N'<logic-app-user-assigned-identity-name>') IS NULL
    CREATE USER [<logic-app-user-assigned-identity-name>] WITH SID = <logic-app-user-assigned-identity-sid>, TYPE = E;
GO

IF DATABASE_PRINCIPAL_ID(N'<reviewer-entra-group-name>') IS NULL
    CREATE USER [<reviewer-entra-group-name>] WITH SID = <reviewer-entra-group-sid>, TYPE = X;
GO

IF DATABASE_PRINCIPAL_ID(N'<supervisor-entra-group-name>') IS NULL
    CREATE USER [<supervisor-entra-group-name>] WITH SID = <supervisor-entra-group-sid>, TYPE = X;
GO

-- ---------------------------------------------------------------------------
-- Function App identity (IngressProcessingFunction):
--   * Idempotency check-and-register requires SELECT (the WHERE NOT EXISTS
--     subquery) and INSERT on IdempotencyLedger.
--   * Append-only decision trail recording requires INSERT only on
--     DecisionTrail -- never UPDATE/DELETE, and no access to dbo.Documents at
--     all (the Function never writes business records; only Logic Apps does,
--     after the authoritative rules evaluation / reviewer decision).
-- ---------------------------------------------------------------------------
GRANT SELECT, INSERT ON dbo.IdempotencyLedger TO [<function-app-identity-name>];
GRANT INSERT ON dbo.DecisionTrail TO [<function-app-identity-name>];
GRANT EXECUTE ON dbo.usp_RegisterBlobVersion TO [<function-app-identity-name>];
GRANT EXECUTE ON dbo.usp_GetProcessingWorkItem TO [<function-app-identity-name>];
GRANT EXECUTE ON dbo.usp_ClaimDocumentHash TO [<function-app-identity-name>];
GRANT EXECUTE ON dbo.usp_UpdateProcessingState TO [<function-app-identity-name>];
GRANT EXECUTE ON dbo.usp_GetProcessingStatus TO [<function-app-identity-name>];
GRANT EXECUTE ON dbo.usp_FindStaleProcessingItems TO [<function-app-identity-name>];
GO

-- ---------------------------------------------------------------------------
-- Logic App identity (business-rules-workflow, human-approval-workflow,
-- sla-notification-workflow). This is the USER-ASSIGNED identity that
-- src/logicapps/connections.json selects explicitly for the SQL built-in
-- connector ("authentication": { "type": "ManagedServiceIdentity",
-- "identity": "@appsetting('Sql_UserAssignedIdentityResourceId')" }), so the
-- contained user below MUST be that identity's resource name -- NOT the Logic
-- App's system-assigned identity, which is used only by the built-in Blob
-- connector and never touches SQL.
--
-- SELECT is required in addition to INSERT because every workflow INSERT is
-- written as a conditional "INSERT ... SELECT ... WHERE NOT EXISTS" so it is
-- safe to retry, and because the SLA workflow reads the decision trail to
-- decide whether a reminder/escalation is still warranted. UNMASK lets it
-- reason about the real PHI values it just wrote.
-- ---------------------------------------------------------------------------
GRANT SELECT, INSERT ON dbo.DecisionTrail TO [<logic-app-user-assigned-identity-name>];
GRANT SELECT, INSERT ON dbo.Documents TO [<logic-app-user-assigned-identity-name>];
GRANT UNMASK ON dbo.Documents TO [<logic-app-user-assigned-identity-name>];
GRANT SELECT, INSERT, UPDATE ON dbo.ProcessingInbox TO [<logic-app-user-assigned-identity-name>];
GRANT SELECT, INSERT, UPDATE ON dbo.WorkflowOperations TO [<logic-app-user-assigned-identity-name>];
GRANT EXECUTE ON dbo.usp_UpdateProcessingState TO [<logic-app-user-assigned-identity-name>];
GRANT EXECUTE ON dbo.usp_GetProcessingStatus TO [<logic-app-user-assigned-identity-name>];
GRANT EXECUTE ON dbo.usp_ClaimWorkflowOperation TO [<logic-app-user-assigned-identity-name>];
GRANT EXECUTE ON dbo.usp_CompleteWorkflowOperation TO [<logic-app-user-assigned-identity-name>];
GO

-- ---------------------------------------------------------------------------
-- Reviewer / supervisor Entra ID groups: read-only access to the review
-- experience data (decision trail + approved documents), with UNMASK so
-- authorized reviewers see real PHI values -- never raw storage access (that
-- remains scoped to the Function/Logic App identities only, per least
-- privilege).
-- ---------------------------------------------------------------------------
GRANT SELECT ON dbo.DecisionTrail TO [<reviewer-entra-group-name>];
GRANT SELECT ON dbo.Documents TO [<reviewer-entra-group-name>];
GRANT UNMASK ON dbo.Documents TO [<reviewer-entra-group-name>];

GRANT SELECT ON dbo.DecisionTrail TO [<supervisor-entra-group-name>];
GRANT SELECT ON dbo.Documents TO [<supervisor-entra-group-name>];
GRANT UNMASK ON dbo.Documents TO [<supervisor-entra-group-name>];
GO

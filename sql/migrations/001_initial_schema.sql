-- =============================================================================
-- Migration 001: Initial schema for the Document Intake AI system of record.
-- =============================================================================
-- Design notes:
--  * dbo.IdempotencyLedger and dbo.DecisionTrail carry NO PHI -- they exist to
--    support idempotent, at-least-once processing and a full, immutable audit
--    trail (classifier version, confidence, rule fired, approver identity,
--    timestamp, outcome) without ever storing document content or extracted
--    field VALUES. DecisionTrail.Detail may name which fields were missing,
--    never their values.
--  * dbo.Documents is the only table holding extracted PHI field values
--    (PatientIdentifier, DateOfService, Provider, and the catch-all
--    ExtractedFieldsJson for any additional extracted fields). These columns
--    are protected with Dynamic Data Masking in this migration -- see the
--    header comment in 002_ddm_masking.sql for why DDM (not Always Encrypted)
--    is the primary, connector-compatible mechanism here, and
--    sql/always-encrypted/ for the implementable Always Encrypted upgrade
--    path.
--  * dbo.DecisionTrail is intentionally append-only (no UPDATE/DELETE grants in
--    003_users_and_permissions.sql) so it remains a trustworthy audit record.
--    SLA reminder/escalation bookkeeping is done by inserting additional rows
--    (Stage='SlaMonitoring', Outcome='ReminderSent'/'Escalated') rather than
--    mutating a separate state table, and 'PendingReview' is the durable
--    record that lets human-approval-workflow return an acceptance response
--    before waiting hours or days for a reviewer.
--  * Run migrations in numeric order with sqlcmd/Invoke-Sqlcmd using Entra ID
--    authentication (Authentication=ActiveDirectoryDefault or
--    ActiveDirectoryManagedIdentity) -- there is no SQL login on this server.
-- =============================================================================

CREATE TABLE dbo.IdempotencyLedger
(
    DocumentHash    CHAR(64)         NOT NULL CONSTRAINT PK_IdempotencyLedger PRIMARY KEY,
    DocumentId      UNIQUEIDENTIFIER NOT NULL,
    BlobName        NVARCHAR(400)    NOT NULL,
    CreatedAtUtc    DATETIME2(3)     NOT NULL CONSTRAINT DF_IdempotencyLedger_CreatedAtUtc DEFAULT SYSUTCDATETIME()
);
GO

CREATE UNIQUE INDEX IX_IdempotencyLedger_DocumentId ON dbo.IdempotencyLedger (DocumentId);
GO

CREATE TABLE dbo.DecisionTrail
(
    Id                 BIGINT IDENTITY(1,1) NOT NULL CONSTRAINT PK_DecisionTrail PRIMARY KEY,
    DocumentId         UNIQUEIDENTIFIER      NOT NULL,
    DocumentHash       CHAR(64)              NOT NULL,
    BlobName           NVARCHAR(400)         NOT NULL,
    Stage              NVARCHAR(50)          NOT NULL, -- Ingress | BusinessRules | HumanApproval | SlaMonitoring
    ClassifierVersion  NVARCHAR(200)         NOT NULL,
    Confidence         FLOAT                 NULL,
    RuleFired          NVARCHAR(100)         NULL,     -- ConfidenceGate | DocumentTypeGate | RequiredFieldsGate | None
    Outcome            NVARCHAR(100)         NOT NULL, -- RoutedAutoApproveCandidate | RoutedReviewRequired | Duplicate |
                                                        -- Failed | AutoApproved | ForwardedForReview | PendingReview |
                                                        -- Approved | Rejected | ReminderSent | Escalated |
                                                        -- PersistenceFailed
    ApproverIdentity   NVARCHAR(320)         NULL,     -- reviewer/supervisor UPN or 'system-auto-approve'; never a patient identifier
    Detail             NVARCHAR(MAX)         NULL,      -- non-PHI: field NAMES, error codes, raw non-PHI connector metadata
    TimestampUtc       DATETIME2(3)          NOT NULL CONSTRAINT DF_DecisionTrail_TimestampUtc DEFAULT SYSUTCDATETIME()
);
GO

CREATE INDEX IX_DecisionTrail_DocumentId ON dbo.DecisionTrail (DocumentId, TimestampUtc);
CREATE INDEX IX_DecisionTrail_Outcome ON dbo.DecisionTrail (Outcome, TimestampUtc);
GO

CREATE TABLE dbo.Documents
(
    DocumentId          UNIQUEIDENTIFIER NOT NULL CONSTRAINT PK_Documents PRIMARY KEY,
    DocumentHash        CHAR(64)         NOT NULL CONSTRAINT UQ_Documents_DocumentHash UNIQUE,
    BlobName            NVARCHAR(400)    NOT NULL, -- processed/ path after approval; not PHI (opaque generated file name)
    DocumentType        NVARCHAR(200)    NOT NULL, -- classification label; not PHI
    Confidence          FLOAT            NOT NULL,
    -- PHI columns -- see 002_ddm_masking.sql for the masking function applied
    -- to each, and docs/COMPLIANCE.md for the HIPAA safeguard mapping.
    PatientIdentifier   NVARCHAR(200)    NULL,
    DateOfService       NVARCHAR(50)     NULL,
    Provider            NVARCHAR(400)    NULL,
    ExtractedFieldsJson NVARCHAR(MAX)    NULL, -- catch-all for any additional extracted fields beyond the three required ones
    ApprovedBy          NVARCHAR(320)    NOT NULL, -- reviewer/supervisor UPN or 'system-auto-approve'
    ApprovedAtUtc       DATETIME2(3)     NOT NULL CONSTRAINT DF_Documents_ApprovedAtUtc DEFAULT SYSUTCDATETIME()
);
GO

CREATE INDEX IX_Documents_DocumentType ON dbo.Documents (DocumentType, ApprovedAtUtc);
GO

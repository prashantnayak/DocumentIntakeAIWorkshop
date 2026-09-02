-- =============================================================================
-- Migration 003: Durable processing state and recoverable workflow operations.
-- =============================================================================
-- ProcessingInbox is the cross-service source of truth. Durable Functions
-- history carries only DocumentId and state values; source blob names, exact
-- versions, sidecar locations, and failure details remain in Azure SQL.
-- WorkflowOperations implements recoverable leases for email/SLA side effects.
-- =============================================================================

IF OBJECT_ID(N'dbo.ProcessingInbox', N'U') IS NULL
BEGIN
    CREATE TABLE dbo.ProcessingInbox
    (
        DocumentId          UNIQUEIDENTIFIER NOT NULL CONSTRAINT PK_ProcessingInbox PRIMARY KEY,
        StorageAccountName  NVARCHAR(100)    NOT NULL,
        ContainerName       NVARCHAR(63)     NOT NULL,
        BlobName            NVARCHAR(400)    NOT NULL,
        BlobVersionId       NVARCHAR(256)    NOT NULL,
        BlobETag            NVARCHAR(128)    NOT NULL,
        DocumentHash        CHAR(64)         NULL,
        PayloadContainer    NVARCHAR(63)     NULL,
        PayloadBlobName     NVARCHAR(400)    NULL,
        CandidateOutcome    NVARCHAR(50)     NULL,
        RuleFired           NVARCHAR(100)    NULL,
        State               NVARCHAR(50)     NOT NULL,
        FailureCode         NVARCHAR(100)    NULL,
        AttemptCount        INT              NOT NULL CONSTRAINT DF_ProcessingInbox_AttemptCount DEFAULT (0),
        LeaseOwner          NVARCHAR(200)    NULL,
        LeaseExpiresAtUtc   DATETIME2(3)     NULL,
        CreatedAtUtc        DATETIME2(3)     NOT NULL CONSTRAINT DF_ProcessingInbox_CreatedAtUtc DEFAULT SYSUTCDATETIME(),
        UpdatedAtUtc        DATETIME2(3)     NOT NULL CONSTRAINT DF_ProcessingInbox_UpdatedAtUtc DEFAULT SYSUTCDATETIME(),
        CONSTRAINT CK_ProcessingInbox_State CHECK
        (
            State IN
            (
                'Registered', 'Processing', 'Analyzed', 'Ready', 'Dispatched',
                'ReviewPending', 'AutoApproved', 'Approved', 'Rejected',
                'Duplicate', 'Failed'
            )
        )
    );
END;
GO

IF COL_LENGTH(N'dbo.ProcessingInbox', N'PayloadContainer') IS NULL
    ALTER TABLE dbo.ProcessingInbox ADD PayloadContainer NVARCHAR(63) NULL;
GO

IF COL_LENGTH(N'dbo.ProcessingInbox', N'CandidateOutcome') IS NULL
    ALTER TABLE dbo.ProcessingInbox ADD CandidateOutcome NVARCHAR(50) NULL;
GO

IF COL_LENGTH(N'dbo.ProcessingInbox', N'RuleFired') IS NULL
    ALTER TABLE dbo.ProcessingInbox ADD RuleFired NVARCHAR(100) NULL;
GO

IF OBJECT_ID(N'dbo.CK_ProcessingInbox_State', N'C') IS NOT NULL
    ALTER TABLE dbo.ProcessingInbox DROP CONSTRAINT CK_ProcessingInbox_State;
GO

ALTER TABLE dbo.ProcessingInbox WITH CHECK ADD CONSTRAINT CK_ProcessingInbox_State CHECK
(
    State IN
    (
        'Registered', 'Processing', 'Analyzed', 'Ready', 'Dispatched',
        'ReviewPending', 'AutoApproved', 'Approved', 'Rejected',
        'Duplicate', 'Failed'
    )
);
GO

IF NOT EXISTS
(
    SELECT 1
    FROM sys.indexes
    WHERE object_id = OBJECT_ID(N'dbo.ProcessingInbox')
      AND name = N'UX_ProcessingInbox_BlobVersion'
)
BEGIN
    CREATE UNIQUE INDEX UX_ProcessingInbox_BlobVersion
        ON dbo.ProcessingInbox
        (
            StorageAccountName,
            ContainerName,
            BlobName,
            BlobVersionId
        );
END;
GO

IF NOT EXISTS
(
    SELECT 1
    FROM sys.indexes
    WHERE object_id = OBJECT_ID(N'dbo.ProcessingInbox')
      AND name = N'UX_ProcessingInbox_DocumentHash'
)
BEGIN
    CREATE UNIQUE INDEX UX_ProcessingInbox_DocumentHash
        ON dbo.ProcessingInbox (DocumentHash)
        WHERE DocumentHash IS NOT NULL
          AND State <> 'Duplicate';
END;
GO

IF NOT EXISTS
(
    SELECT 1
    FROM sys.indexes
    WHERE object_id = OBJECT_ID(N'dbo.ProcessingInbox')
      AND name = N'IX_ProcessingInbox_StateUpdated'
)
BEGIN
    CREATE INDEX IX_ProcessingInbox_StateUpdated
        ON dbo.ProcessingInbox (State, UpdatedAtUtc)
        INCLUDE (DocumentId, AttemptCount, LeaseExpiresAtUtc);
END;
GO

IF OBJECT_ID(N'dbo.WorkflowOperations', N'U') IS NULL
BEGIN
    CREATE TABLE dbo.WorkflowOperations
    (
        DocumentId          UNIQUEIDENTIFIER NOT NULL,
        OperationType       NVARCHAR(100)    NOT NULL,
        State               NVARCHAR(30)     NOT NULL,
        LeaseOwner          NVARCHAR(200)    NULL,
        LeaseExpiresAtUtc   DATETIME2(3)     NULL,
        AttemptCount        INT              NOT NULL CONSTRAINT DF_WorkflowOperations_AttemptCount DEFAULT (0),
        SentAtUtc           DATETIME2(3)     NULL,
        LastErrorCode       NVARCHAR(100)    NULL,
        CreatedAtUtc        DATETIME2(3)     NOT NULL CONSTRAINT DF_WorkflowOperations_CreatedAtUtc DEFAULT SYSUTCDATETIME(),
        UpdatedAtUtc        DATETIME2(3)     NOT NULL CONSTRAINT DF_WorkflowOperations_UpdatedAtUtc DEFAULT SYSUTCDATETIME(),
        CONSTRAINT PK_WorkflowOperations PRIMARY KEY (DocumentId, OperationType),
        CONSTRAINT FK_WorkflowOperations_ProcessingInbox
            FOREIGN KEY (DocumentId) REFERENCES dbo.ProcessingInbox (DocumentId),
        CONSTRAINT CK_WorkflowOperations_State CHECK
        (
            State IN ('Pending', 'Leased', 'Sent', 'Completed', 'Failed')
        )
    );
END;
GO

CREATE OR ALTER PROCEDURE dbo.usp_RegisterBlobVersion
    @StorageAccountName NVARCHAR(100),
    @ContainerName      NVARCHAR(63),
    @BlobName           NVARCHAR(400),
    @BlobVersionId      NVARCHAR(256),
    @BlobETag           NVARCHAR(128)
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    BEGIN TRANSACTION;

    DECLARE @DocumentId UNIQUEIDENTIFIER;

    SELECT @DocumentId = DocumentId
    FROM dbo.ProcessingInbox WITH (UPDLOCK, HOLDLOCK)
    WHERE StorageAccountName = @StorageAccountName
      AND ContainerName = @ContainerName
      AND BlobName = @BlobName
      AND BlobVersionId = @BlobVersionId;

    IF @DocumentId IS NULL
    BEGIN
        SET @DocumentId = NEWID();

        INSERT dbo.ProcessingInbox
        (
            DocumentId,
            StorageAccountName,
            ContainerName,
            BlobName,
            BlobVersionId,
            BlobETag,
            State
        )
        VALUES
        (
            @DocumentId,
            @StorageAccountName,
            @ContainerName,
            @BlobName,
            @BlobVersionId,
            @BlobETag,
            'Registered'
        );
    END;

    COMMIT TRANSACTION;

    SELECT DocumentId, State
    FROM dbo.ProcessingInbox
    WHERE DocumentId = @DocumentId;
END;
GO

CREATE OR ALTER PROCEDURE dbo.usp_GetProcessingWorkItem
    @DocumentId UNIQUEIDENTIFIER
AS
BEGIN
    SET NOCOUNT ON;

    SELECT
        DocumentId,
        StorageAccountName,
        ContainerName,
        BlobName,
        BlobVersionId,
        BlobETag,
        DocumentHash,
        PayloadContainer,
        PayloadBlobName,
        CandidateOutcome,
        RuleFired,
        State,
        FailureCode,
        AttemptCount,
        LeaseOwner,
        LeaseExpiresAtUtc,
        CreatedAtUtc,
        UpdatedAtUtc
    FROM dbo.ProcessingInbox
    WHERE DocumentId = @DocumentId;
END;
GO

CREATE OR ALTER PROCEDURE dbo.usp_ClaimDocumentHash
    @DocumentId   UNIQUEIDENTIFIER,
    @DocumentHash CHAR(64)
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    BEGIN TRANSACTION;

    DECLARE @CanonicalDocumentId UNIQUEIDENTIFIER;

    SELECT @CanonicalDocumentId = DocumentId
    FROM dbo.ProcessingInbox WITH (UPDLOCK, HOLDLOCK)
    WHERE DocumentHash = @DocumentHash
      AND State <> 'Duplicate';

    IF @CanonicalDocumentId IS NOT NULL
       AND @CanonicalDocumentId <> @DocumentId
    BEGIN
        UPDATE dbo.ProcessingInbox
        SET
            DocumentHash = @DocumentHash,
            State = 'Duplicate',
            FailureCode = NULL,
            LeaseOwner = NULL,
            LeaseExpiresAtUtc = NULL,
            UpdatedAtUtc = SYSUTCDATETIME()
        WHERE DocumentId = @DocumentId;

        COMMIT TRANSACTION;

        SELECT
            CAST(1 AS BIT) AS IsDuplicate,
            @CanonicalDocumentId AS CanonicalDocumentId;
        RETURN;
    END;

    UPDATE dbo.ProcessingInbox
    SET
        DocumentHash = @DocumentHash,
        State = CASE
            WHEN State IN ('Registered', 'Failed') THEN 'Processing'
            ELSE State
        END,
        FailureCode = NULL,
        AttemptCount = AttemptCount + 1,
        UpdatedAtUtc = SYSUTCDATETIME()
    WHERE DocumentId = @DocumentId;

    COMMIT TRANSACTION;

    SELECT
        CAST(0 AS BIT) AS IsDuplicate,
        @DocumentId AS CanonicalDocumentId;
END;
GO

CREATE OR ALTER PROCEDURE dbo.usp_UpdateProcessingState
    @DocumentId      UNIQUEIDENTIFIER,
    @State           NVARCHAR(50),
    @ExpectedState   NVARCHAR(50) = NULL,
    @DocumentHash    CHAR(64) = NULL,
    @PayloadContainer NVARCHAR(63) = NULL,
    @PayloadBlobName NVARCHAR(400) = NULL,
    @CandidateOutcome NVARCHAR(50) = NULL,
    @RuleFired       NVARCHAR(100) = NULL,
    @FailureCode     NVARCHAR(100) = NULL,
    @ClearPayload    BIT = 0
AS
BEGIN
    SET NOCOUNT ON;

    UPDATE dbo.ProcessingInbox
    SET
        State = @State,
        DocumentHash = COALESCE(@DocumentHash, DocumentHash),
        PayloadContainer = CASE
            WHEN @ClearPayload = 1 THEN NULL
            WHEN @PayloadContainer IS NOT NULL THEN @PayloadContainer
            ELSE PayloadContainer
        END,
        PayloadBlobName = CASE
            WHEN @ClearPayload = 1 THEN NULL
            WHEN @PayloadBlobName IS NOT NULL THEN @PayloadBlobName
            ELSE PayloadBlobName
        END,
        CandidateOutcome = COALESCE(@CandidateOutcome, CandidateOutcome),
        RuleFired = COALESCE(@RuleFired, RuleFired),
        FailureCode = @FailureCode,
        LeaseOwner = NULL,
        LeaseExpiresAtUtc = NULL,
        UpdatedAtUtc = SYSUTCDATETIME()
    WHERE DocumentId = @DocumentId
      AND (@ExpectedState IS NULL OR State = @ExpectedState);

    SELECT @@ROWCOUNT AS RowsUpdated;
END;
GO

CREATE OR ALTER PROCEDURE dbo.usp_GetProcessingStatus
    @DocumentId UNIQUEIDENTIFIER
AS
BEGIN
    SET NOCOUNT ON;

    SELECT DocumentId, State, AttemptCount, UpdatedAtUtc
    FROM dbo.ProcessingInbox
    WHERE DocumentId = @DocumentId;
END;
GO

CREATE OR ALTER PROCEDURE dbo.usp_FindStaleProcessingItems
    @OlderThanUtc DATETIME2(3),
    @MaxRows      INT = 100
AS
BEGIN
    SET NOCOUNT ON;

    SELECT TOP (@MaxRows) DocumentId, State, AttemptCount, UpdatedAtUtc
    FROM dbo.ProcessingInbox
    WHERE State IN ('Registered', 'Processing', 'Analyzed', 'Ready', 'Dispatched')
      AND UpdatedAtUtc < @OlderThanUtc
      AND (LeaseExpiresAtUtc IS NULL OR LeaseExpiresAtUtc < SYSUTCDATETIME())
    ORDER BY UpdatedAtUtc;
END;
GO

CREATE OR ALTER PROCEDURE dbo.usp_ClaimWorkflowOperation
    @DocumentId       UNIQUEIDENTIFIER,
    @OperationType    NVARCHAR(100),
    @LeaseOwner       NVARCHAR(200),
    @LeaseDurationMin INT = 15
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    BEGIN TRANSACTION;

    IF NOT EXISTS
    (
        SELECT 1
        FROM dbo.WorkflowOperations WITH (UPDLOCK, HOLDLOCK)
        WHERE DocumentId = @DocumentId
          AND OperationType = @OperationType
    )
    BEGIN
        INSERT dbo.WorkflowOperations
        (
            DocumentId,
            OperationType,
            State
        )
        VALUES
        (
            @DocumentId,
            @OperationType,
            'Pending'
        );
    END;

    UPDATE dbo.WorkflowOperations
    SET
        State = 'Leased',
        LeaseOwner = @LeaseOwner,
        LeaseExpiresAtUtc = DATEADD(MINUTE, @LeaseDurationMin, SYSUTCDATETIME()),
        AttemptCount = AttemptCount + 1,
        LastErrorCode = NULL,
        UpdatedAtUtc = SYSUTCDATETIME()
    WHERE DocumentId = @DocumentId
      AND OperationType = @OperationType
      AND State IN ('Pending', 'Failed', 'Leased')
      AND (State <> 'Leased' OR LeaseExpiresAtUtc < SYSUTCDATETIME());

    DECLARE @Claimed BIT = IIF(@@ROWCOUNT = 1, 1, 0);

    COMMIT TRANSACTION;

    SELECT @Claimed AS Claimed;
END;
GO

CREATE OR ALTER PROCEDURE dbo.usp_CompleteWorkflowOperation
    @DocumentId    UNIQUEIDENTIFIER,
    @OperationType NVARCHAR(100),
    @LeaseOwner    NVARCHAR(200),
    @Succeeded     BIT,
    @ErrorCode     NVARCHAR(100) = NULL
AS
BEGIN
    SET NOCOUNT ON;

    UPDATE dbo.WorkflowOperations
    SET
        State = IIF(@Succeeded = 1, 'Sent', 'Failed'),
        SentAtUtc = IIF(@Succeeded = 1, SYSUTCDATETIME(), SentAtUtc),
        LastErrorCode = @ErrorCode,
        LeaseOwner = NULL,
        LeaseExpiresAtUtc = NULL,
        UpdatedAtUtc = SYSUTCDATETIME()
    WHERE DocumentId = @DocumentId
      AND OperationType = @OperationType
      AND State = 'Leased'
      AND LeaseOwner = @LeaseOwner;

    SELECT @@ROWCOUNT AS RowsUpdated;
END;
GO

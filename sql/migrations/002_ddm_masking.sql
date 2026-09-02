-- =============================================================================
-- Migration 002: Dynamic Data Masking on PHI columns in dbo.Documents.
-- =============================================================================
-- WHY DDM AND NOT ALWAYS ENCRYPTED HERE:
-- dbo.Documents is written and read by the Logic Apps business-rules and
-- human-approval workflows through the Standard built-in SQL connector
-- (serviceProviderConnections -> /serviceProviders/sql, operationId
-- executeQuery). Always Encrypted requires the calling DATA-ACCESS CLIENT to
-- be Always-Encrypted-aware: it must hold (or be able to fetch) the column
-- master key and transparently encrypt/decrypt parameters and result sets. No
-- Microsoft documentation confirms the Logic Apps Standard built-in SQL
-- connector implements Always Encrypted-aware parameter handling, so wiring
-- Always Encrypted directly onto columns the connector writes is not a
-- verifiable, implementable claim -- see docs/ASSUMPTIONS.md.
--
-- Dynamic Data Masking has no such client requirement: masking is enforced by
-- the Database Engine itself at query time based on the caller's UNMASK
-- permission, so it works transparently through ANY client, including the
-- Logic Apps connector. It is therefore the PRIMARY, working PHI protection
-- for these connector-written columns. Always Encrypted remains available as
-- a documented, implementable defense-in-depth upgrade for deployments that
-- route persistence through a dedicated Python persistence activity using an
-- Always Encrypted-capable ODBC configuration instead -- see
-- sql/always-encrypted/README.md for that migration path.
--
-- Masking functions used:
--  * PatientIdentifier -> partial(1, "XXXXXXXX", 0): reveals only the first
--    character, e.g. "P1234567" -> "PXXXXXXXX".
--  * DateOfService      -> default(): fully masked as "XXXX-XX-XX"-style
--    default for string types ("xxxx" in practice for nvarchar).
--  * Provider           -> partial(2, "XXXXXXXX", 0): reveals only the first
--    two characters.
--  * ExtractedFieldsJson -> default(): fully masked; this column can contain
--    any additional PHI-adjacent extracted text.
-- =============================================================================

ALTER TABLE dbo.Documents
    ALTER COLUMN PatientIdentifier NVARCHAR(200)
    MASKED WITH (FUNCTION = 'partial(1, "XXXXXXXX", 0)') NULL;
GO

ALTER TABLE dbo.Documents
    ALTER COLUMN DateOfService NVARCHAR(50)
    MASKED WITH (FUNCTION = 'default()') NULL;
GO

ALTER TABLE dbo.Documents
    ALTER COLUMN Provider NVARCHAR(400)
    MASKED WITH (FUNCTION = 'partial(2, "XXXXXXXX", 0)') NULL;
GO

ALTER TABLE dbo.Documents
    ALTER COLUMN ExtractedFieldsJson NVARCHAR(MAX)
    MASKED WITH (FUNCTION = 'default()') NULL;
GO

-- UNMASK is granted only to the identities that must see plaintext PHI to do
-- their job (the Logic Apps workflow identity for persistence/decisioning,
-- and the reviewer/supervisor Entra ID groups for the review experience).
-- Replace the principal names below with the actual contained database users
-- created by scripts/post-deploy.ps1 for this environment before running.
-- General read access (e.g. ad hoc reporting) intentionally does NOT include
-- UNMASK, so those callers see masked placeholders instead of PHI.
--
-- GRANT UNMASK ON dbo.Documents TO [<logic-app-user-assigned-identity-name>];
-- GRANT UNMASK ON dbo.Documents TO [<reviewer-entra-group-name>];
-- GRANT UNMASK ON dbo.Documents TO [<supervisor-entra-group-name>];

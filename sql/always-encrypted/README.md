# Always Encrypted Upgrade

Dynamic Data Masking is the deployed control for PHI columns in
`dbo.Documents`. This directory is an optional upgrade to client-side Always
Encrypted and is not applied by the normal migration sequence.

## Prerequisite decision

Always Encrypted requires an aware client driver to encrypt parameters and
decrypt results. The Logic Apps built-in SQL connector is not documented as
providing that behavior. Before enabling this plan, choose one:

1. move `dbo.Documents` persistence into the Python Function and use an
   Always-Encrypted-capable Python SQL driver/configuration; or
2. prove the deployed Logic Apps SQL connector can round-trip a test encrypted
   column in the target tenant.

Do not encrypt production columns until the selected writer has passed
read/write, retry, rotation, and recovery tests.

## Procedure

Run `configure-always-encrypted.ps1` from the private Windows test VM or another
VNet-connected administration host. Use a dedicated Key Vault key; do not reuse
the SQL TDE protector.

```powershell
.\sql\always-encrypted\configure-always-encrypted.ps1 `
  -SqlServerFqdn '<server>.database.windows.net' `
  -DatabaseName '<database>' `
  -KeyVaultKeyUri 'https://<vault>.vault.azure.net/keys/<dedicated-ae-key>/<version>' `
  -WhatIf
```

Review the script help and output, back up the schema, schedule downtime, and
then rerun without `-WhatIf`. Converting columns rewrites data and requires
dropping their masking clauses because a column cannot use both controls.

## Python writer requirements

If persistence moves to Python:

- configure the chosen driver for Always Encrypted;
- keep Entra managed-identity authentication;
- grant the Function identity only the Key Vault `get`, `wrapKey`, and
  `unwrapKey` rights needed on the dedicated key;
- use parameterized inserts and keep extracted values out of logs and Durable
  orchestration history;
- update `src/functions/intake/repository.py` or a dedicated persistence module,
  not the Logic App sidecar transport;
- test key-cache expiry, cold start, retries, and operation idempotency through
  `dbo.WorkflowOperations`.

`pyodbc` access in `src/functions/intake/repository.py` currently supports
processing-state procedures; this document does not claim that its present
configuration enables Always Encrypted.

## Rotation and rollback

- Rotate the column master key using the supported SQL tooling and re-encrypt
  the column encryption key.
- Keep old key versions enabled until all readers have refreshed and recovery
  has been tested.
- To roll back, decrypt the columns with an authorized client, then reapply
  `sql/migrations/002_ddm_masking.sql`.

Always Encrypted does not replace SQL TDE, private endpoints, TLS, least
privilege, audit controls, or the 35-day workshop backup limitation.

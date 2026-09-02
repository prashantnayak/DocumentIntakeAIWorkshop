from __future__ import annotations

import struct
import uuid
from collections.abc import Callable, Sequence
from typing import Any, Protocol

from azure.core.credentials import TokenCredential

from .models import ProcessingWorkItem, value_from_row

SQL_COPT_SS_ACCESS_TOKEN = 1256
SQL_SCOPE = "https://database.windows.net/.default"


class ProcessingRepository(Protocol):
    def register_blob_version(
        self,
        source_account: str,
        source_container: str,
        source_blob_name: str,
        source_version_id: str,
        source_etag: str,
    ) -> str: ...

    def claim_document_hash(self, document_id: str, document_hash: str) -> str: ...

    def get_work_item(self, document_id: str) -> ProcessingWorkItem: ...

    def update_state(
        self,
        document_id: str,
        state: str,
        *,
        expected_state: str | None = None,
        failure_code: str | None = None,
        document_hash: str | None = None,
        payload_container: str | None = None,
        payload_blob_name: str | None = None,
        candidate_outcome: str | None = None,
        rule_fired: str | None = None,
    ) -> None: ...

    def get_status(self, document_id: str) -> str: ...

    def find_stale_items(self) -> list[str]: ...


def normalize_document_id(value: Any) -> str:
    return str(uuid.UUID(str(value)))


class SqlProcessingRepository:
    """Parameterized stored-procedure access using an Entra access token."""

    def __init__(
        self,
        server: str,
        database: str,
        credential: TokenCredential,
        connect: Callable[..., Any] | None = None,
    ) -> None:
        self._credential = credential
        self._connect = connect or self._default_connect
        self._connection_string = (
            "DRIVER={ODBC Driver 18 for SQL Server};"
            f"SERVER=tcp:{server},1433;DATABASE={database};"
            "Encrypt=yes;TrustServerCertificate=no;Connection Timeout=30"
        )

    def _default_connect(self, connection_string: str, **kwargs: Any) -> Any:
        import pyodbc

        return pyodbc.connect(connection_string, **kwargs)

    def _open(self) -> Any:
        token = self._credential.get_token(SQL_SCOPE).token.encode("utf-16-le")
        packed_token = struct.pack(f"<I{len(token)}s", len(token), token)
        return self._connect(
            self._connection_string,
            attrs_before={SQL_COPT_SS_ACCESS_TOKEN: packed_token},
            autocommit=False,
        )

    @staticmethod
    def _row(cursor: Any, row: Any) -> dict[str, Any]:
        names = [column[0] for column in cursor.description or ()]
        return dict(zip(names, row, strict=False))

    def _execute_one(self, sql: str, parameters: Sequence[Any]) -> dict[str, Any]:
        connection = self._open()
        try:
            cursor = connection.cursor()
            cursor.execute(sql, *parameters)
            row = cursor.fetchone()
            connection.commit()
            if row is None:
                raise RuntimeError("Expected stored procedure result")
            return self._row(cursor, row)
        except Exception:
            connection.rollback()
            raise
        finally:
            connection.close()

    def _execute_all(self, sql: str, parameters: Sequence[Any]) -> list[dict[str, Any]]:
        connection = self._open()
        try:
            cursor = connection.cursor()
            cursor.execute(sql, *parameters)
            rows = cursor.fetchall()
            connection.commit()
            return [self._row(cursor, row) for row in rows]
        except Exception:
            connection.rollback()
            raise
        finally:
            connection.close()

    def _execute(self, sql: str, parameters: Sequence[Any]) -> None:
        connection = self._open()
        try:
            cursor = connection.cursor()
            cursor.execute(sql, *parameters)
            connection.commit()
        except Exception:
            connection.rollback()
            raise
        finally:
            connection.close()

    def register_blob_version(
        self,
        source_account: str,
        source_container: str,
        source_blob_name: str,
        source_version_id: str,
        source_etag: str,
    ) -> str:
        row = self._execute_one(
            """
            EXEC dbo.usp_RegisterBlobVersion
                @StorageAccountName=?, @ContainerName=?, @BlobName=?,
                @BlobVersionId=?, @BlobETag=?
            """,
            (
                source_account,
                source_container,
                source_blob_name,
                source_version_id,
                source_etag,
            ),
        )
        return normalize_document_id(value_from_row(row, "DocumentId"))

    def claim_document_hash(self, document_id: str, document_hash: str) -> str:
        row = self._execute_one(
            """
            EXEC dbo.usp_ClaimDocumentHash @DocumentId=?, @DocumentHash=?
            """,
            (normalize_document_id(document_id), document_hash),
        )
        is_duplicate = bool(value_from_row(row, "IsDuplicate", False))
        return "Duplicate" if is_duplicate else "Claimed"

    def update_state(
        self,
        document_id: str,
        state: str,
        *,
        expected_state: str | None = None,
        failure_code: str | None = None,
        document_hash: str | None = None,
        payload_container: str | None = None,
        payload_blob_name: str | None = None,
        candidate_outcome: str | None = None,
        rule_fired: str | None = None,
    ) -> None:
        self._execute(
            """
            EXEC dbo.usp_UpdateProcessingState
                @DocumentId=?, @State=?, @ExpectedState=?, @FailureCode=?,
                @DocumentHash=?, @PayloadContainer=?, @PayloadBlobName=?,
                @CandidateOutcome=?, @RuleFired=?
            """,
            (
                normalize_document_id(document_id),
                state,
                expected_state,
                failure_code,
                document_hash,
                payload_container,
                payload_blob_name,
                candidate_outcome,
                rule_fired,
            ),
        )

    def get_work_item(self, document_id: str) -> ProcessingWorkItem:
        row = self._execute_one(
            "EXEC dbo.usp_GetProcessingWorkItem @DocumentId=?",
            (normalize_document_id(document_id),),
        )
        return ProcessingWorkItem(
            document_id=normalize_document_id(value_from_row(row, "DocumentId")),
            source_account=str(value_from_row(row, "StorageAccountName")),
            source_container=str(value_from_row(row, "ContainerName")),
            source_blob_name=str(value_from_row(row, "BlobName")),
            source_version_id=str(value_from_row(row, "BlobVersionId")),
            source_etag=str(value_from_row(row, "BlobETag")),
            state=str(value_from_row(row, "State", "Registered")),
            payload_container=value_from_row(row, "PayloadContainer"),
            payload_blob_name=value_from_row(row, "PayloadBlobName"),
            dispatch_state=None,
        )

    def get_status(self, document_id: str) -> str:
        row = self._execute_one(
            "EXEC dbo.usp_GetProcessingStatus @DocumentId=?",
            (normalize_document_id(document_id),),
        )
        return str(value_from_row(row, "State", "Pending"))

    def find_stale_items(self) -> list[str]:
        rows = self._execute_all("EXEC dbo.usp_FindStaleProcessingItems", ())
        return [
            normalize_document_id(value_from_row(row, "DocumentId")) for row in rows
        ]

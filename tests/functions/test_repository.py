from __future__ import annotations

import uuid
from types import SimpleNamespace

from intake.repository import SQL_COPT_SS_ACCESS_TOKEN, SqlProcessingRepository


class FakeCursor:
    def __init__(self, row: tuple[object, ...], columns: tuple[str, ...]) -> None:
        self.result = row
        self.description = [(column,) for column in columns]
        self.sql = ""
        self.parameters: tuple[object, ...] = ()

    def execute(self, sql: str, *parameters: object) -> None:
        self.sql = sql
        self.parameters = parameters

    def fetchone(self) -> tuple[object, ...]:
        return self.result


class FakeConnection:
    def __init__(self, cursor: FakeCursor) -> None:
        self._cursor = cursor
        self.committed = False
        self.closed = False

    def cursor(self) -> FakeCursor:
        return self._cursor

    def commit(self) -> None:
        self.committed = True

    def rollback(self) -> None:
        pass

    def close(self) -> None:
        self.closed = True


def test_register_uses_token_and_parameterized_stored_procedure() -> None:
    document_id = uuid.uuid4()
    cursor = FakeCursor((document_id,), ("DocumentId",))
    connection = FakeConnection(cursor)
    calls: list[dict[str, object]] = []

    def connect(connection_string: str, **kwargs: object) -> FakeConnection:
        calls.append({"connection_string": connection_string, **kwargs})
        return connection

    credential = SimpleNamespace(
        get_token=lambda scope: SimpleNamespace(token="entra-token")
    )
    repository = SqlProcessingRepository(
        "server.database.windows.net", "database", credential, connect
    )
    result = repository.register_blob_version(
        "account", "documents", "incoming/name.pdf", "version", '"etag"'
    )

    assert result == str(document_id)
    assert "usp_RegisterBlobVersion" in cursor.sql
    assert "incoming/name.pdf" not in cursor.sql
    assert cursor.parameters[2] == "incoming/name.pdf"
    assert SQL_COPT_SS_ACCESS_TOKEN in calls[0]["attrs_before"]
    assert "PWD=" not in calls[0]["connection_string"]
    assert connection.committed and connection.closed


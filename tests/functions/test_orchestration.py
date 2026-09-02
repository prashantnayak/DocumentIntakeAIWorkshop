from __future__ import annotations

import asyncio
import json
from datetime import UTC, datetime
from pathlib import Path
from types import SimpleNamespace

import function_app


class FakeContext:
    def __init__(self, document_id: str) -> None:
        self.document_id = document_id
        self.current_utc_datetime = datetime(2026, 1, 1, tzinfo=UTC)
        self.continued_with: str | None = None

    def get_input(self) -> str:
        return self.document_id

    def call_activity_with_retry(
        self, name: str, retry_options: object, value: str
    ) -> tuple[str, str, str]:
        del retry_options
        return ("activity", name, value)

    def create_timer(self, deadline: datetime) -> tuple[str, datetime]:
        return ("timer", deadline)

    def continue_as_new(self, value: str) -> None:
        self.continued_with = value


class FakeClient:
    def __init__(self, status: object | None = None) -> None:
        self.status = status
        self.started: list[tuple[str, str, str]] = []
        self.purged: list[str] = []

    async def get_status(self, instance_id: str) -> object | None:
        return self.status

    async def start_new(
        self, name: str, *, instance_id: str, client_input: str
    ) -> None:
        self.started.append((name, instance_id, client_input))

    async def purge_instance_history(self, instance_id: str) -> None:
        self.purged.append(instance_id)


def test_orchestration_history_contains_only_document_id_and_status() -> None:
    document_id = "3b5e74f8-08d2-49c1-ae50-bfeafbd0a96b"
    context = FakeContext(document_id)
    generator = function_app.orchestration_logic(context)

    yielded = next(generator)
    assert yielded == ("activity", "ProcessAndStage", document_id)
    yielded = generator.send("Ready")
    assert yielded == ("activity", "InvokeBusinessWorkflow", document_id)
    yielded = generator.send("Dispatched")
    assert yielded == ("activity", "PollProcessingStatus", document_id)
    yielded = generator.send("Approved")
    assert yielded == ("activity", "FinalizeSource", document_id)
    try:
        generator.send("Approved")
    except StopIteration as stopped:
        assert stopped.value == {"DocumentId": document_id, "State": "Approved"}
    else:
        raise AssertionError("orchestration did not terminate")


def test_pending_status_uses_timer_and_continue_as_new(monkeypatch) -> None:
    monkeypatch.setattr(function_app, "POLLS_PER_GENERATION", 1)
    context = FakeContext("3b5e74f8-08d2-49c1-ae50-bfeafbd0a96b")
    generator = function_app.orchestration_logic(context)

    next(generator)
    generator.send("Ready")
    generator.send("Dispatched")
    timer = generator.send("Pending")
    assert timer[0] == "timer"
    try:
        generator.send(None)
    except StopIteration:
        pass
    assert context.continued_with == context.document_id


def test_terminal_duplicate_skips_dispatch() -> None:
    context = FakeContext("3b5e74f8-08d2-49c1-ae50-bfeafbd0a96b")
    generator = function_app.orchestration_logic(context)
    next(generator)
    yielded = generator.send("Duplicate")
    assert yielded == ("activity", "FinalizeSource", context.document_id)
    try:
        generator.send("Duplicate")
    except StopIteration as stopped:
        assert stopped.value["State"] == "Duplicate"


def test_starter_is_deterministic_and_idempotent() -> None:
    document_id = "3b5e74f8-08d2-49c1-ae50-bfeafbd0a96b"
    client = FakeClient()
    assert asyncio.run(function_app.ensure_started(client, document_id))
    assert client.started == [
        (
            "DocumentOrchestrator",
            f"document-{document_id}",
            document_id,
        )
    ]

    existing = FakeClient(SimpleNamespace(runtime_status="Running"))
    assert not asyncio.run(function_app.ensure_started(existing, document_id))
    assert existing.started == []


def test_reconciliation_restarts_only_inactive_instances() -> None:
    document_id = "3b5e74f8-08d2-49c1-ae50-bfeafbd0a96b"
    active = FakeClient(SimpleNamespace(runtime_status="Running"))
    assert not asyncio.run(function_app.reconcile_one(active, document_id))

    completed = FakeClient(SimpleNamespace(runtime_status="Completed"))
    assert asyncio.run(function_app.reconcile_one(completed, document_id))
    assert completed.purged == [f"document-{document_id}"]
    assert completed.started[0][1] == f"document-{document_id}"


def test_generated_bindings_use_polling_blob_and_disable_phi_tracing() -> None:
    functions = {
        item.get_function_name(): [
            binding.get_dict_repr() for binding in item.get_bindings()
        ]
        for item in function_app.app.get_functions()
    }
    blob = next(
        binding
        for binding in functions["DocumentBlobStarter"]
        if binding["type"] == "blobTrigger"
    )
    assert blob["path"] == "%PhiStorage__ContainerName%/%PhiStorage__IncomingPrefix%/{name}"
    assert blob["connection"] == "PhiStorage"
    assert blob["source"] == "LogsAndContainerScan"

    host_path = Path(function_app.__file__).with_name("host.json")
    host = json.loads(host_path.read_text(encoding="utf-8"))
    assert (
        host["extensions"]["durableTask"]["tracing"]["traceInputsAndOutputs"]
        is False
    )

    local_settings = json.loads(
        host_path.with_name("local.settings.sample.json").read_text(encoding="utf-8")
    )["Values"]
    assert local_settings["PhiStorage__blobServiceUri"]
    assert local_settings["PhiStorage__credential"] == "managedidentity"
    assert "PhiStorage__clientId" in local_settings
    assert "PhiStorage__queueServiceUri" not in local_settings
    assert "AzureWebJobsStorage" in local_settings

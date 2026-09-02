from __future__ import annotations

import json
import uuid
from types import SimpleNamespace

import pytest

from intake.blob_service import PhiBlobService
from intake.models import (
    ClassificationResult,
    ProcessingState,
    ProcessingWorkItem,
)
from intake.document_service import DocumentAnalysisService
from intake.processing_service import DocumentProcessingService
from intake.registration_service import SourceRegistrationService
from intake.routing import DeterministicRoutingService
from intake.workflow_service import BusinessWorkflowService


def work_item(**overrides: object) -> ProcessingWorkItem:
    values = {
        "document_id": str(uuid.uuid4()),
        "source_account": "account",
        "source_container": "documents",
        "source_blob_name": "incoming/private.pdf",
        "source_version_id": "version",
        "source_etag": '"etag"',
        "state": "Registered",
        "payload_container": None,
        "payload_blob_name": None,
        "dispatch_state": None,
    }
    values.update(overrides)
    return ProcessingWorkItem(**values)


class FakeRepository:
    def __init__(self, item: ProcessingWorkItem, claim: str = "Claimed") -> None:
        self.item = item
        self.claim = claim
        self.updates: list[tuple[str, str, dict[str, object]]] = []
        self.register_args: tuple[str, ...] | None = None

    def get_work_item(self, document_id: str) -> ProcessingWorkItem:
        return self.item

    def claim_document_hash(self, document_id: str, document_hash: str) -> str:
        return self.claim

    def update_state(self, document_id: str, state: str, **kwargs: object) -> None:
        self.updates.append((document_id, state, kwargs))

    def register_blob_version(self, *args: str) -> str:
        self.register_args = args
        return self.item.document_id


class FakeBlobs:
    def __init__(self) -> None:
        self.payload: dict[str, object] | None = None

    def list_blob_names(self, prefix: str, max_results: int) -> tuple[str, ...]:
        assert prefix == "incoming/"
        assert max_results == 100
        return ("incoming/private.pdf",)

    def resolve_identity(self, blob_name: str) -> SimpleNamespace:
        return SimpleNamespace(
            account_name="account",
            container_name="documents",
            blob_name=blob_name,
            version_id="version",
            etag='"etag"',
        )

    def download_exact(self, item: ProcessingWorkItem) -> tuple[bytes, str]:
        return b"content", "hash"

    def create_read_sas(self, item: ProcessingWorkItem) -> tuple[str, str]:
        return "https://private/blob?sig=secret", "2026-01-01T00:00:00Z"

    def write_workflow_payload(
        self, document_id: str, payload: dict[str, object]
    ) -> tuple[str, str]:
        self.payload = payload
        return "documents", f"workflow-payloads/{document_id}.json"

    def move_to_failed(self, item: ProcessingWorkItem, code: str) -> None:
        pass

    def delete_source_if_current(self, item: ProcessingWorkItem) -> None:
        pass

    def delete_workflow_payload(self, item: ProcessingWorkItem) -> None:
        pass


def test_registration_uses_exact_version_identity() -> None:
    item = work_item()
    repository = FakeRepository(item)
    service = SourceRegistrationService(
        repository, FakeBlobs(), "documents", "incoming/", 100
    )
    result = service.register_trigger(
        SimpleNamespace(name="documents/incoming/private.pdf")
    )
    assert result == item.document_id
    assert repository.register_args == (
        "account",
        "documents",
        "incoming/private.pdf",
        "version",
        '"etag"',
    )


def test_polling_registration_uses_exact_version_identity() -> None:
    item = work_item()
    repository = FakeRepository(item)
    service = SourceRegistrationService(
        repository, FakeBlobs(), "documents", "incoming/", 100
    )

    blob_names = service.list_pending_blob_names()
    assert blob_names == ("incoming/private.pdf",)
    assert service.register_blob_name(blob_names[0]) == item.document_id
    assert repository.register_args == (
        "account",
        "documents",
        "incoming/private.pdf",
        "version",
        '"etag"',
    )


def test_read_sas_preserves_exact_blob_version(monkeypatch: pytest.MonkeyPatch) -> None:
    item = work_item()
    blob = SimpleNamespace(
        url="https://account.blob.core.windows.net/documents/incoming/private.pdf"
    )
    client = SimpleNamespace(
        account_name="account",
        get_user_delegation_key=lambda start, expiry: object(),
        get_blob_client=lambda container, name, version_id: blob,
    )
    credential = SimpleNamespace()
    monkeypatch.setattr(
        "intake.blob_service.generate_blob_sas",
        lambda **kwargs: "sv=test&sig=secret",
    )
    service = PhiBlobService(
        client,
        credential,
        "documents",
        "failed/",
        "workflow-payloads/",
        24,
    )

    url, _ = service.create_read_sas(item)

    assert url == (
        "https://account.blob.core.windows.net/documents/incoming/private.pdf"
        "?versionid=version&sv=test&sig=secret"
    )


def test_document_analysis_matches_colon_terminated_field_labels() -> None:
    pairs = [
        SimpleNamespace(
            key=SimpleNamespace(content="Patient Identifier:"),
            value=SimpleNamespace(content="SYN-TEST-0000001"),
        ),
        SimpleNamespace(
            key=SimpleNamespace(content="Date of Service :"),
            value=SimpleNamespace(content="2020-01-01"),
        ),
        SimpleNamespace(
            key=SimpleNamespace(content="Provider:"),
            value=SimpleNamespace(content="Dr. Sample Synthetic MD"),
        ),
    ]
    extraction = SimpleNamespace(
        pages=[SimpleNamespace()],
        content="synthetic content",
        key_value_pairs=pairs,
    )
    analyzer = DocumentAnalysisService(
        SimpleNamespace(
            begin_analyze_document=lambda *args, **kwargs: SimpleNamespace(
                result=lambda: extraction
            )
        ),
        "prebuilt-layout",
        "",
        ("PatientIdentifier", "DateOfService", "Provider"),
        {
            "PatientIdentifier": ["Patient Identifier"],
            "DateOfService": ["Date of Service"],
        },
    )

    result = analyzer.analyze(b"synthetic")

    assert result.confidence == 1.0
    assert result.required_field_values == {
        "PatientIdentifier": "SYN-TEST-0000001",
        "DateOfService": "2020-01-01",
        "Provider": "Dr. Sample Synthetic MD",
    }


def test_duplicate_stops_before_analysis() -> None:
    item = work_item()
    repository = FakeRepository(item, claim="Duplicate")
    analyzer = SimpleNamespace(
        analyze=lambda content: (_ for _ in ()).throw(
            AssertionError("must not analyze duplicate")
        )
    )
    service = DocumentProcessingService(
        repository,
        FakeBlobs(),
        analyzer,
        DeterministicRoutingService(0.85, ()),
    )
    assert service.process_and_stage(item.document_id) == "Duplicate"
    assert repository.updates[-1][1] == "Duplicate"


def test_processing_stages_phi_only_in_sidecar() -> None:
    item = work_item()
    repository = FakeRepository(item)
    blobs = FakeBlobs()
    analyzer = SimpleNamespace(
        analyze=lambda content: ClassificationResult(
            document_type="Claim",
            confidence=0.95,
            required_field_values={"PatientIdentifier": "sensitive-value"},
            low_quality=False,
            classifier_version="model",
            page_count=1,
            extracted_content_length=10,
        )
    )
    service = DocumentProcessingService(
        repository,
        blobs,
        analyzer,
        DeterministicRoutingService(0.85, ()),
    )
    assert service.process_and_stage(item.document_id) == "Ready"
    assert blobs.payload is not None
    assert blobs.payload["requiredFieldValues"] == {
        "PatientIdentifier": "sensitive-value"
    }
    ready_update = repository.updates[-1]
    assert ready_update[1] == "Ready"
    assert "sensitive-value" not in repr(ready_update)
    assert "sig=secret" not in repr(ready_update)


def test_workflow_post_contains_only_opaque_reference() -> None:
    item = work_item(
        state=ProcessingState.READY.value,
        payload_container="documents",
        payload_blob_name="workflow-payloads/opaque.json",
    )
    repository = FakeRepository(item)
    captured: dict[str, object] = {}

    def transport(request: object, timeout: float) -> int:
        captured["body"] = json.loads(request.data)
        captured["timeout"] = timeout
        return 202

    service = BusinessWorkflowService(
        repository, "https://workflow.example/invoke?secret=kv", transport
    )
    assert service.invoke(item.document_id) == "Dispatched"
    assert captured["body"] == {
        "documentId": item.document_id,
        "sidecarBlobName": "workflow-payloads/opaque.json",
    }
    assert repository.updates[-1][1] == "Dispatched"


def test_finalization_preserves_a_newer_overwrite() -> None:
    current = SimpleNamespace(
        deleted=False,
        get_blob_properties=lambda: SimpleNamespace(
            etag='"new-etag"', version_id="new-version"
        ),
    )

    def delete_blob(**kwargs: object) -> None:
        current.deleted = True

    current.delete_blob = delete_blob
    client = SimpleNamespace(get_blob_client=lambda *args, **kwargs: current)
    blobs = PhiBlobService(
        client,
        SimpleNamespace(),
        "documents",
        "failed/",
        "workflow-payloads/",
        24,
    )
    blobs.delete_source_if_current(
        work_item(source_etag='"old-etag"', source_version_id="old-version")
    )
    assert current.deleted is False

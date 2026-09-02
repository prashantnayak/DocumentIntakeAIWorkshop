from __future__ import annotations

from dataclasses import dataclass
from enum import StrEnum
from typing import Any


class ProcessingState(StrEnum):
    REGISTERED = "Registered"
    PROCESSING = "Processing"
    READY = "Ready"
    DISPATCHED = "Dispatched"
    REVIEW_PENDING = "ReviewPending"
    PENDING = "Pending"
    AUTO_APPROVED = "AutoApproved"
    APPROVED = "Approved"
    REJECTED = "Rejected"
    FAILED = "Failed"
    DUPLICATE = "Duplicate"


TERMINAL_STATES = frozenset(
    {
        ProcessingState.AUTO_APPROVED.value,
        ProcessingState.APPROVED.value,
        ProcessingState.REJECTED.value,
        ProcessingState.FAILED.value,
        ProcessingState.DUPLICATE.value,
    }
)


@dataclass(frozen=True)
class BlobIdentity:
    account_name: str
    container_name: str
    blob_name: str
    version_id: str
    etag: str


@dataclass(frozen=True)
class ProcessingWorkItem:
    document_id: str
    source_account: str
    source_container: str
    source_blob_name: str
    source_version_id: str
    source_etag: str
    state: str
    payload_container: str | None = None
    payload_blob_name: str | None = None
    dispatch_state: str | None = None


@dataclass(frozen=True)
class ClassificationResult:
    document_type: str
    confidence: float
    required_field_values: dict[str, str | None]
    low_quality: bool
    classifier_version: str
    page_count: int
    extracted_content_length: int


@dataclass(frozen=True)
class RoutingDecision:
    candidate_outcome: str
    rule_fired: str
    missing_required_fields: tuple[str, ...]


def value_from_row(row: dict[str, Any], name: str, default: Any = None) -> Any:
    wanted = name.casefold()
    for key, value in row.items():
        if key.casefold() == wanted:
            return value
    return default

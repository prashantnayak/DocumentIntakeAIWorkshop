from __future__ import annotations

import json
import os
from dataclasses import dataclass, field
from pathlib import Path


def _setting(name: str, default: str = "") -> str:
    return os.getenv(name, default)


def _json_list(name: str, default: list[str]) -> list[str]:
    raw = _setting(name)
    if not raw:
        return default
    value = json.loads(raw)
    if not isinstance(value, list) or not all(isinstance(item, str) for item in value):
        raise ValueError(f"{name} must be a JSON string array")
    return value


@dataclass(frozen=True)
class Settings:
    managed_identity_client_id: str = field(
        default_factory=lambda: _setting("ManagedIdentity__ClientId")
    )
    blob_service_uri: str = field(
        default_factory=lambda: _setting("PhiStorage__blobServiceUri")
    )
    container_name: str = field(
        default_factory=lambda: _setting("PhiStorage__ContainerName", "documents")
    )
    incoming_prefix: str = field(
        default_factory=lambda: _setting("PhiStorage__IncomingPrefix", "incoming")
        .strip("/")
        + "/"
    )
    polling_batch_size: int = field(
        default_factory=lambda: max(
            1, min(1000, int(_setting("IntakePollingBatchSize", "100")))
        )
    )
    reconciliation_stale_minutes: int = field(
        default_factory=lambda: max(
            5, int(_setting("ReconciliationStaleMinutes", "15"))
        )
    )
    failed_prefix: str = field(
        default_factory=lambda: _setting("PhiStorage__FailedPrefix", "failed")
        .strip("/")
        + "/"
    )
    payload_prefix: str = field(
        default_factory=lambda: _setting(
            "PhiStorage__WorkflowPayloadPrefix", "workflow-payloads"
        ).strip("/")
        + "/"
    )
    document_intelligence_endpoint: str = field(
        default_factory=lambda: _setting("DocumentIntelligence__Endpoint")
    )
    extraction_model_id: str = field(
        default_factory=lambda: _setting(
            "DocumentIntelligence__ExtractionModelId", "prebuilt-layout"
        )
    )
    classifier_model_id: str = field(
        default_factory=lambda: _setting("DocumentIntelligence__ClassifierModelId")
    )
    sql_server: str = field(default_factory=lambda: _setting("Sql__DataSource"))
    sql_database: str = field(
        default_factory=lambda: _setting("Sql__InitialCatalog", "sqldb-intake")
    )
    workflow_url: str = field(
        default_factory=lambda: _setting("BusinessRulesWorkflowUrl")
    )
    confidence_threshold: float = field(
        default_factory=lambda: float(
            _setting("BusinessRules__ConfidenceThreshold", "0.85")
        )
    )
    high_risk_document_types: tuple[str, ...] = field(
        default_factory=lambda: tuple(
            _json_list(
                "BusinessRules__HighRiskDocumentTypesJson",
                ["Consent Form", "Advance Directive", "Prior Authorization"],
            )
        )
    )
    required_fields: tuple[str, ...] = field(
        default_factory=lambda: tuple(
            _json_list(
                "BusinessRules__RequiredFieldsJson",
                ["PatientIdentifier", "DateOfService", "Provider"],
            )
        )
    )
    sas_expiry_hours: int = field(
        default_factory=lambda: max(
            1, int(_setting("BusinessRules__SasLinkExpiryHours", "72"))
        )
    )
    field_aliases: dict[str, list[str]] = field(default_factory=dict)

    @classmethod
    def from_environment(cls) -> "Settings":
        aliases_path = (
            Path(__file__).resolve().parent.parent
            / "config"
            / "required-field-aliases.json"
        )
        aliases = json.loads(aliases_path.read_text(encoding="utf-8"))
        return cls(field_aliases=aliases)

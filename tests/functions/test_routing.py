from __future__ import annotations

from intake.models import ClassificationResult
from intake.routing import DeterministicRoutingService


def result(
    *,
    confidence: float = 0.95,
    document_type: str = "Claim",
    fields: dict[str, str | None] | None = None,
) -> ClassificationResult:
    return ClassificationResult(
        document_type=document_type,
        confidence=confidence,
        required_field_values=fields
        or {"PatientIdentifier": "present", "DateOfService": "present"},
        low_quality=False,
        classifier_version="test",
        page_count=1,
        extracted_content_length=10,
    )


def test_routing_gate_precedence_and_auto_approve() -> None:
    service = DeterministicRoutingService(0.85, ("Consent Form",))

    assert service.evaluate(result(confidence=0.5)).rule_fired == "ConfidenceGate"
    assert (
        service.evaluate(result(document_type="consent form")).rule_fired
        == "DocumentTypeGate"
    )
    missing = service.evaluate(
        result(fields={"PatientIdentifier": "present", "DateOfService": None})
    )
    assert missing.rule_fired == "RequiredFieldsGate"
    assert missing.missing_required_fields == ("DateOfService",)
    assert service.evaluate(result()).candidate_outcome == "AutoApproveCandidate"


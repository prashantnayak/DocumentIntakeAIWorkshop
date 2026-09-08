from __future__ import annotations

from .models import ClassificationResult, RoutingDecision


class DeterministicRoutingService:
    def __init__(
        self, confidence_threshold: float, high_risk_document_types: tuple[str, ...]
    ) -> None:
        self._threshold = confidence_threshold
        self._high_risk = {value.casefold() for value in high_risk_document_types}

    def evaluate(self, result: ClassificationResult) -> RoutingDecision:
        missing = tuple(
            name
            for name, value in result.required_field_values.items()
            if value is None or not value.strip()
        )
        if result.confidence < self._threshold:
            return RoutingDecision("ReviewRequired", "ConfidenceGate", missing)
        if result.document_type.casefold() in self._high_risk:
            return RoutingDecision("ReviewRequired", "DocumentTypeGate", missing)
        if missing:
            return RoutingDecision("ReviewRequired", "RequiredFieldsGate", missing)
        return RoutingDecision("AutoApproveCandidate", "None", ())


from __future__ import annotations

from typing import Any

from azure.ai.documentintelligence import DocumentIntelligenceClient
from azure.ai.documentintelligence.models import (
    AnalyzeDocumentRequest,
    ClassifyDocumentRequest,
    DocumentAnalysisFeature,
)

from .models import ClassificationResult


def _text(value: Any) -> str | None:
    content = getattr(value, "content", None)
    return str(content).strip() if content else None


def _normalize_key(value: str) -> str:
    return " ".join(value.strip().rstrip(":").split()).casefold()


class DocumentAnalysisService:
    def __init__(
        self,
        client: DocumentIntelligenceClient,
        extraction_model_id: str,
        classifier_model_id: str,
        required_fields: tuple[str, ...],
        aliases: dict[str, list[str]],
    ) -> None:
        self._client = client
        self._extraction_model_id = extraction_model_id
        self._classifier_model_id = classifier_model_id
        self._required_fields = required_fields
        self._aliases = aliases

    def analyze(self, content: bytes) -> ClassificationResult:
        poller = self._client.begin_analyze_document(
            self._extraction_model_id,
            body=AnalyzeDocumentRequest(bytes_source=content),
            features=[DocumentAnalysisFeature.KEY_VALUE_PAIRS],
        )
        extraction = poller.result()
        page_count = len(getattr(extraction, "pages", None) or [])
        extracted_content = getattr(extraction, "content", None) or ""
        values = self._resolve_required_fields(
            getattr(extraction, "key_value_pairs", None) or []
        )

        document_type = "GeneralIntakeDocument"
        found = sum(bool(value) for value in values.values())
        confidence = found / max(1, len(self._required_fields))
        classifier_version = f"deterministic-fallback|{self._extraction_model_id}"

        if self._classifier_model_id:
            classification = self._client.begin_classify_document(
                self._classifier_model_id,
                body=ClassifyDocumentRequest(bytes_source=content),
            ).result()
            documents = getattr(classification, "documents", None) or []
            if documents:
                document_type = str(
                    getattr(documents[0], "doc_type", None)
                    or getattr(documents[0], "document_type", None)
                    or "Unclassified"
                )
                confidence = float(getattr(documents[0], "confidence", 0.0) or 0.0)
            else:
                document_type = "Unclassified"
                confidence = 0.0
            classifier_version = (
                f"{self._classifier_model_id}|{self._extraction_model_id}|"
                f"{getattr(classification, 'api_version', 'unknown')}"
            )

        return ClassificationResult(
            document_type=document_type,
            confidence=confidence,
            required_field_values=values,
            low_quality=page_count == 0 or len(extracted_content) == 0,
            classifier_version=classifier_version,
            page_count=page_count,
            extracted_content_length=len(extracted_content),
        )

    def _resolve_required_fields(self, pairs: list[Any]) -> dict[str, str | None]:
        result: dict[str, str | None] = {}
        for required in self._required_fields:
            accepted = {
                _normalize_key(required),
                *(
                    _normalize_key(alias)
                    for alias in self._aliases.get(required, [])
                ),
            }
            result[required] = None
            for pair in pairs:
                key = _text(getattr(pair, "key", None))
                value = _text(getattr(pair, "value", None))
                if key and value and _normalize_key(key) in accepted:
                    result[required] = value
                    break
        return result

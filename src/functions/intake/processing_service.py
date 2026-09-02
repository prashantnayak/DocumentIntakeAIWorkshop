from __future__ import annotations

from datetime import UTC, datetime

from .blob_service import PhiBlobService
from .document_service import DocumentAnalysisService
from .models import ProcessingState, TERMINAL_STATES
from .repository import ProcessingRepository
from .routing import DeterministicRoutingService


class DocumentProcessingService:
    def __init__(
        self,
        repository: ProcessingRepository,
        blobs: PhiBlobService,
        analyzer: DocumentAnalysisService,
        routing: DeterministicRoutingService,
    ) -> None:
        self._repository = repository
        self._blobs = blobs
        self._analyzer = analyzer
        self._routing = routing

    def process_and_stage(self, document_id: str) -> str:
        item = self._repository.get_work_item(document_id)
        if item.state in TERMINAL_STATES:
            return item.state
        if item.state == ProcessingState.REVIEW_PENDING.value:
            return item.state
        if item.payload_container and item.payload_blob_name:
            return ProcessingState.READY.value

        self._repository.update_state(
            document_id, ProcessingState.PROCESSING.value
        )
        content, document_hash = self._blobs.download_exact(item)
        claim = self._repository.claim_document_hash(document_id, document_hash)
        if claim.casefold() in {"duplicate", "alreadyclaimedbyanother"}:
            self._repository.update_state(
                document_id,
                ProcessingState.DUPLICATE.value,
                document_hash=document_hash,
            )
            return ProcessingState.DUPLICATE.value

        classification = self._analyzer.analyze(content)
        if classification.low_quality:
            self._repository.update_state(
                document_id,
                ProcessingState.FAILED.value,
                failure_code="LOW_QUALITY_DOCUMENT",
                document_hash=document_hash,
            )
            return ProcessingState.FAILED.value

        decision = self._routing.evaluate(classification)
        access_url, access_expires = self._blobs.create_read_sas(item)
        payload = {
            "documentId": document_id,
            "blobName": item.source_blob_name,
            "sourceVersionId": item.source_version_id,
            "documentHash": document_hash,
            "documentType": classification.document_type,
            "confidence": classification.confidence,
            "classifierVersion": classification.classifier_version,
            "requiredFieldValues": classification.required_field_values,
            "missingRequiredFields": list(decision.missing_required_fields),
            "candidateOutcome": decision.candidate_outcome,
            "ruleFired": decision.rule_fired,
            "accessLinkUrl": access_url,
            "accessLinkExpiresOn": access_expires,
            "ingestedAtUtc": datetime.now(UTC).isoformat(),
        }
        payload_container, payload_blob_name = self._blobs.write_workflow_payload(
            document_id, payload
        )
        self._repository.update_state(
            document_id,
            ProcessingState.READY.value,
            document_hash=document_hash,
            payload_container=payload_container,
            payload_blob_name=payload_blob_name,
            candidate_outcome=decision.candidate_outcome,
            rule_fired=decision.rule_fired,
        )
        return ProcessingState.READY.value

    def compensate(self, document_id: str, failure_code: str) -> str:
        item = self._repository.get_work_item(document_id)
        self._repository.update_state(
            document_id,
            ProcessingState.FAILED.value,
            failure_code=failure_code,
        )
        cleanup_failed = False
        try:
            self._blobs.move_to_failed(item, failure_code)
        except Exception:
            cleanup_failed = True
        try:
            self._blobs.delete_workflow_payload(item)
        except Exception:
            cleanup_failed = True
        if cleanup_failed:
            raise RuntimeError("COMPENSATION_CLEANUP_FAILED")
        return ProcessingState.FAILED.value

    def finalize_source(self, document_id: str) -> str:
        item = self._repository.get_work_item(document_id)
        self._blobs.delete_source_if_current(item)
        return item.state

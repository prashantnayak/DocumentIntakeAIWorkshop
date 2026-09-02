from __future__ import annotations

from functools import lru_cache

from azure.ai.documentintelligence import DocumentIntelligenceClient
from azure.identity import DefaultAzureCredential
from azure.storage.blob import BlobServiceClient

from .blob_service import PhiBlobService
from .document_service import DocumentAnalysisService
from .processing_service import DocumentProcessingService
from .registration_service import SourceRegistrationService
from .repository import SqlProcessingRepository
from .routing import DeterministicRoutingService
from .settings import Settings
from .workflow_service import BusinessWorkflowService


@lru_cache(maxsize=1)
def services() -> dict[str, object]:
    settings = Settings.from_environment()
    credential = DefaultAzureCredential(
        managed_identity_client_id=settings.managed_identity_client_id or None
    )
    repository = SqlProcessingRepository(
        settings.sql_server,
        settings.sql_database,
        credential,
        stale_after_minutes=settings.reconciliation_stale_minutes,
    )
    blob_client = BlobServiceClient(settings.blob_service_uri, credential)
    blobs = PhiBlobService(
        blob_client,
        credential,
        settings.container_name,
        settings.failed_prefix,
        settings.payload_prefix,
        settings.sas_expiry_hours,
    )
    analyzer = DocumentAnalysisService(
        DocumentIntelligenceClient(
            settings.document_intelligence_endpoint, credential
        ),
        settings.extraction_model_id,
        settings.classifier_model_id,
        settings.required_fields,
        settings.field_aliases,
    )
    routing = DeterministicRoutingService(
        settings.confidence_threshold, settings.high_risk_document_types
    )
    return {
        "repository": repository,
        "registration": SourceRegistrationService(
            repository,
            blobs,
            settings.container_name,
            settings.incoming_prefix,
            settings.polling_batch_size,
        ),
        "processing": DocumentProcessingService(
            repository, blobs, analyzer, routing
        ),
        "workflow": BusinessWorkflowService(
            repository, settings.workflow_url
        ),
    }

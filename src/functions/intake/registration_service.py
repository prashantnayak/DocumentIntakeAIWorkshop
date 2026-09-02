from __future__ import annotations

from typing import Any

from .blob_service import PhiBlobService
from .repository import ProcessingRepository


class SourceRegistrationService:
    def __init__(
        self,
        repository: ProcessingRepository,
        blobs: PhiBlobService,
        container_name: str,
        incoming_prefix: str,
    ) -> None:
        self._repository = repository
        self._blobs = blobs
        self._container_name = container_name
        self._incoming_prefix = incoming_prefix

    def register_trigger(self, source_blob: Any) -> str:
        bound_name = str(source_blob.name).replace("\\", "/").lstrip("/")
        container_prefix = f"{self._container_name}/"
        blob_name = (
            bound_name[len(container_prefix) :]
            if bound_name.startswith(container_prefix)
            else bound_name
        )
        if not blob_name.startswith(self._incoming_prefix):
            raise RuntimeError("Blob is outside the incoming prefix")
        identity = self._blobs.resolve_identity(blob_name)
        return self._repository.register_blob_version(
            identity.account_name,
            identity.container_name,
            identity.blob_name,
            identity.version_id,
            identity.etag,
        )


from __future__ import annotations

import hashlib
import json
from datetime import UTC, datetime, timedelta
from typing import Any

from azure.core import MatchConditions
from azure.core.credentials import TokenCredential
from azure.core.exceptions import ResourceNotFoundError
from azure.storage.blob import (
    BlobSasPermissions,
    BlobServiceClient,
    ContentSettings,
    generate_blob_sas,
)

from .models import BlobIdentity, ProcessingWorkItem


class PhiBlobService:
    def __init__(
        self,
        client: BlobServiceClient,
        credential: TokenCredential,
        container_name: str,
        failed_prefix: str,
        payload_prefix: str,
        sas_expiry_hours: int,
    ) -> None:
        self._client = client
        self._credential = credential
        self._container_name = container_name
        self._failed_prefix = failed_prefix
        self._payload_prefix = payload_prefix
        self._sas_expiry_hours = sas_expiry_hours

    def resolve_identity(self, blob_name: str) -> BlobIdentity:
        blob_client = self._client.get_blob_client(self._container_name, blob_name)
        properties = blob_client.get_blob_properties()
        version_id = getattr(properties, "version_id", None)
        etag = str(properties.etag)
        if not version_id:
            versions = self._client.get_container_client(
                self._container_name
            ).list_blobs(name_starts_with=blob_name, include=["versions"])
            exact = [
                item
                for item in versions
                if item.name == blob_name
                and str(item.etag) == etag
                and getattr(item, "version_id", None)
            ]
            current = [
                item for item in exact if getattr(item, "is_current_version", False)
            ]
            if current:
                version_id = current[0].version_id
            elif len(exact) == 1:
                version_id = exact[0].version_id
            else:
                raise RuntimeError("Blob version identity unavailable")
        return BlobIdentity(
            account_name=self._client.account_name,
            container_name=self._container_name,
            blob_name=blob_name,
            version_id=str(version_id),
            etag=etag,
        )

    def download_exact(self, item: ProcessingWorkItem) -> tuple[bytes, str]:
        if item.source_account.casefold() != self._client.account_name.casefold():
            raise RuntimeError("Source account does not match configured storage")
        blob = self._client.get_blob_client(
            item.source_container,
            item.source_blob_name,
            version_id=item.source_version_id,
        )
        content = blob.download_blob(
            etag=item.source_etag,
            match_condition=MatchConditions.IfNotModified,
        ).readall()
        return content, hashlib.sha256(content).hexdigest()

    def create_read_sas(self, item: ProcessingWorkItem) -> tuple[str, str]:
        starts_on = datetime.now(UTC) - timedelta(minutes=5)
        expires_on = datetime.now(UTC) + timedelta(hours=self._sas_expiry_hours)
        delegation_key = self._client.get_user_delegation_key(starts_on, expires_on)
        query = generate_blob_sas(
            account_name=self._client.account_name,
            container_name=item.source_container,
            blob_name=item.source_blob_name,
            version_id=item.source_version_id,
            user_delegation_key=delegation_key,
            permission=BlobSasPermissions(read=True),
            start=starts_on,
            expiry=expires_on,
            protocol="https",
        )
        blob = self._client.get_blob_client(
            item.source_container,
            item.source_blob_name,
            version_id=item.source_version_id,
        )
        blob_url = blob.url.split("?", 1)[0]
        return f"{blob_url}?{query}", expires_on.isoformat()

    def write_workflow_payload(
        self, document_id: str, payload: dict[str, Any]
    ) -> tuple[str, str]:
        blob_name = f"{self._payload_prefix}{document_id}.json"
        data = json.dumps(payload, separators=(",", ":")).encode("utf-8")
        blob = self._client.get_blob_client(self._container_name, blob_name)
        blob.upload_blob(
            data,
            overwrite=True,
            content_settings=ContentSettings(content_type="application/json"),
        )
        return self._container_name, blob_name

    def move_to_failed(self, item: ProcessingWorkItem, failure_code: str) -> None:
        source = self._client.get_blob_client(
            item.source_container,
            item.source_blob_name,
            version_id=item.source_version_id,
        )
        current = self._client.get_blob_client(
            item.source_container, item.source_blob_name
        )
        try:
            properties = current.get_blob_properties()
        except ResourceNotFoundError:
            return
        if str(properties.etag) != item.source_etag:
            return
        current_version = getattr(properties, "version_id", None)
        if current_version and str(current_version) != item.source_version_id:
            return

        destination = self._client.get_blob_client(
            item.source_container,
            f"{self._failed_prefix}{item.document_id}",
        )
        access_token = self._credential.get_token(
            "https://storage.azure.com/.default"
        ).token
        destination.upload_blob_from_url(
            source.url,
            overwrite=True,
            metadata={"failureCode": failure_code},
            source_authorization=f"Bearer {access_token}",
            source_if_match=item.source_etag,
        )
        current.delete_blob(
            etag=item.source_etag,
            match_condition=MatchConditions.IfNotModified,
        )

    def delete_source_if_current(self, item: ProcessingWorkItem) -> None:
        current = self._client.get_blob_client(
            item.source_container, item.source_blob_name
        )
        try:
            properties = current.get_blob_properties()
        except ResourceNotFoundError:
            return
        if str(properties.etag) != item.source_etag:
            return
        current_version = getattr(properties, "version_id", None)
        if current_version and str(current_version) != item.source_version_id:
            return
        current.delete_blob(
            etag=item.source_etag,
            match_condition=MatchConditions.IfNotModified,
        )

    def delete_workflow_payload(self, item: ProcessingWorkItem) -> None:
        if not item.payload_container or not item.payload_blob_name:
            return
        payload = self._client.get_blob_client(
            item.payload_container, item.payload_blob_name
        )
        try:
            payload.delete_blob()
        except ResourceNotFoundError:
            return

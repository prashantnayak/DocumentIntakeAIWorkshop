from __future__ import annotations

import json
from collections.abc import Callable
from urllib.request import Request, urlopen

from .models import ProcessingState
from .repository import ProcessingRepository


class BusinessWorkflowService:
    def __init__(
        self,
        repository: ProcessingRepository,
        workflow_url: str,
        transport: Callable[[Request, float], int] | None = None,
    ) -> None:
        self._repository = repository
        self._workflow_url = workflow_url
        self._transport = transport or self._post

    @staticmethod
    def _post(request: Request, timeout: float) -> int:
        with urlopen(request, timeout=timeout) as response:  # noqa: S310
            return int(response.status)

    def invoke(self, document_id: str) -> str:
        item = self._repository.get_work_item(document_id)
        if item.state in {
            ProcessingState.DISPATCHED.value,
            ProcessingState.REVIEW_PENDING.value,
            ProcessingState.AUTO_APPROVED.value,
            ProcessingState.APPROVED.value,
            ProcessingState.REJECTED.value,
        } or item.dispatch_state in {"Dispatched", "Accepted"}:
            return ProcessingState.DISPATCHED.value
        if not item.payload_container or not item.payload_blob_name:
            raise RuntimeError("Workflow payload reference unavailable")
        if not self._workflow_url:
            raise RuntimeError("Business workflow URL unavailable")

        body = json.dumps(
            {
                "documentId": document_id,
                "sidecarBlobName": item.payload_blob_name,
            },
            separators=(",", ":"),
        ).encode("utf-8")
        request = Request(
            self._workflow_url,
            data=body,
            headers={"Content-Type": "application/json"},
            method="POST",
        )
        status = self._transport(request, 30.0)
        if status < 200 or status >= 300:
            raise RuntimeError("Business workflow rejected dispatch")
        self._repository.update_state(
            document_id,
            ProcessingState.DISPATCHED.value,
            expected_state=ProcessingState.READY.value,
        )
        return ProcessingState.DISPATCHED.value

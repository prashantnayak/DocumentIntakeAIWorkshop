from __future__ import annotations

import logging
from datetime import timedelta
from typing import Any

import azure.durable_functions as df
import azure.functions as func

from intake.container import services
from intake.models import ProcessingState, TERMINAL_STATES
from intake.redaction import configure_safe_logging, safe_log

app = df.DFApp()
logger = logging.getLogger("intake")
configure_safe_logging()

POLL_INTERVAL = timedelta(minutes=2)
POLLS_PER_GENERATION = 20
ACTIVE_RUNTIME_STATES = frozenset({"pending", "running", "continuedasnew"})
ORCHESTRATOR_NAME = "DocumentOrchestrator"


def _service(name: str) -> Any:
    return services()[name]


def _runtime_state(status: Any) -> str:
    runtime = getattr(status, "runtime_status", "")
    value = getattr(runtime, "name", None) or getattr(runtime, "value", None) or runtime
    return str(value).replace("_", "").casefold()


async def ensure_started(client: Any, document_id: str) -> bool:
    instance_id = f"document-{document_id}"
    if await client.get_status(instance_id) is not None:
        return False
    await client.start_new(
        ORCHESTRATOR_NAME,
        instance_id=instance_id,
        client_input=document_id,
    )
    return True


@app.function_name(name="DocumentBlobStarter")
@app.blob_trigger(
    arg_name="source_blob",
    path="%PhiStorage__ContainerName%/%PhiStorage__IncomingPrefix%/{name}",
    connection="PhiStorage",
    source=func.BlobSource.LOGS_AND_CONTAINER_SCAN,
)
@app.durable_client_input(client_name="client")
async def document_blob_starter(
    source_blob: func.InputStream, client: df.DurableOrchestrationClient
) -> None:
    try:
        document_id = _service("registration").register_trigger(source_blob)
        await ensure_started(client, document_id)
        safe_log(logger, logging.INFO, "Blob version registered.", document_id)
    except Exception:
        logger.error("Blob registration failed; trigger will retry.")
        raise RuntimeError("SOURCE_REGISTRATION_FAILED") from None


def orchestration_logic(context: df.DurableOrchestrationContext) -> Any:
    document_id = str(context.get_input())
    retry_options = df.RetryOptions(5000, 3)

    try:
        state = yield context.call_activity_with_retry(
            "ProcessAndStage", retry_options, document_id
        )
    except Exception:
        yield context.call_activity_with_retry(
            "CompensateDocument", retry_options, document_id
        )
        return {"DocumentId": document_id, "State": ProcessingState.FAILED.value}
    if state == ProcessingState.FAILED.value:
        yield context.call_activity_with_retry(
            "CompensateDocument", retry_options, document_id
        )
        return {"DocumentId": document_id, "State": ProcessingState.FAILED.value}
    if state in TERMINAL_STATES:
        if state != ProcessingState.FAILED.value:
            yield context.call_activity_with_retry(
                "FinalizeSource", retry_options, document_id
            )
        return {"DocumentId": document_id, "State": state}

    if state != ProcessingState.REVIEW_PENDING.value:
        try:
            state = yield context.call_activity_with_retry(
                "InvokeBusinessWorkflow", retry_options, document_id
            )
        except Exception:
            yield context.call_activity_with_retry(
                "CompensateDocument", retry_options, document_id
            )
            return {"DocumentId": document_id, "State": ProcessingState.FAILED.value}
        if state == ProcessingState.FAILED.value:
            yield context.call_activity_with_retry(
                "CompensateDocument", retry_options, document_id
            )
            return {"DocumentId": document_id, "State": ProcessingState.FAILED.value}

    for _ in range(POLLS_PER_GENERATION):
        state = yield context.call_activity_with_retry(
            "PollProcessingStatus", retry_options, document_id
        )
        if state in TERMINAL_STATES:
            if state == ProcessingState.FAILED.value:
                yield context.call_activity_with_retry(
                    "CompensateDocument", retry_options, document_id
                )
            else:
                yield context.call_activity_with_retry(
                    "FinalizeSource", retry_options, document_id
                )
            return {"DocumentId": document_id, "State": state}
        deadline = context.current_utc_datetime + POLL_INTERVAL
        yield context.create_timer(deadline)

    context.continue_as_new(document_id)
    return None


@app.function_name(name="DocumentOrchestrator")
@app.orchestration_trigger(context_name="context")
def document_orchestrator(
    context: df.DurableOrchestrationContext,
) -> Any:
    return (yield from orchestration_logic(context))


@app.function_name(name="ProcessAndStage")
@app.activity_trigger(input_name="document_id")
def process_and_stage(document_id: str) -> str:
    try:
        return _service("processing").process_and_stage(document_id)
    except Exception:
        safe_log(logger, logging.ERROR, "Processing activity failed.", document_id)
        raise RuntimeError("PROCESSING_ACTIVITY_FAILED") from None


@app.function_name(name="InvokeBusinessWorkflow")
@app.activity_trigger(input_name="document_id")
def invoke_business_workflow(document_id: str) -> str:
    try:
        return _service("workflow").invoke(document_id)
    except Exception:
        safe_log(logger, logging.ERROR, "Workflow dispatch failed.", document_id)
        raise RuntimeError("WORKFLOW_DISPATCH_FAILED") from None


@app.function_name(name="PollProcessingStatus")
@app.activity_trigger(input_name="document_id")
def poll_processing_status(document_id: str) -> str:
    try:
        state = _service("repository").get_status(document_id)
        return state if state in TERMINAL_STATES else ProcessingState.PENDING.value
    except Exception:
        safe_log(logger, logging.WARNING, "Status poll deferred.", document_id)
        return ProcessingState.PENDING.value


@app.function_name(name="CompensateDocument")
@app.activity_trigger(input_name="document_id")
def compensate_document(document_id: str) -> str:
    try:
        return _service("processing").compensate(
            document_id, "TERMINAL_ACTIVITY_FAILURE"
        )
    except Exception:
        safe_log(logger, logging.ERROR, "Compensation incomplete.", document_id)
        return ProcessingState.FAILED.value


@app.function_name(name="FinalizeSource")
@app.activity_trigger(input_name="document_id")
def finalize_source(document_id: str) -> str:
    try:
        return _service("processing").finalize_source(document_id)
    except Exception:
        safe_log(logger, logging.ERROR, "Source finalization failed.", document_id)
        raise RuntimeError("SOURCE_FINALIZATION_FAILED") from None


async def reconcile_one(client: Any, document_id: str) -> bool:
    instance_id = f"document-{document_id}"
    status = await client.get_status(instance_id)
    if status is not None and _runtime_state(status) in ACTIVE_RUNTIME_STATES:
        return False
    if status is not None:
        await client.purge_instance_history(instance_id)
    await client.start_new(
        ORCHESTRATOR_NAME,
        instance_id=instance_id,
        client_input=document_id,
    )
    return True


@app.function_name(name="ReconcileStaleDocuments")
@app.timer_trigger(
    schedule="%ReconciliationSchedule%",
    arg_name="timer",
    run_on_startup=False,
    use_monitor=True,
)
@app.durable_client_input(client_name="client")
async def reconcile_stale_documents(
    timer: func.TimerRequest, client: df.DurableOrchestrationClient
) -> None:
    del timer
    try:
        document_ids = _service("repository").find_stale_items()
    except Exception:
        logger.error("Stale-document lookup failed.")
        return
    for document_id in document_ids:
        try:
            if await reconcile_one(client, document_id):
                safe_log(
                    logger,
                    logging.INFO,
                    "ProcessingInboxStaleItem restarted.",
                    document_id,
                )
        except Exception:
            safe_log(
                logger,
                logging.ERROR,
                "Stale orchestration restart failed.",
                document_id,
            )

from __future__ import annotations

import logging

from intake.redaction import NoPhiFilter, safe_log


def test_filter_removes_arguments_and_signed_queries() -> None:
    record = logging.LogRecord(
        "intake",
        logging.INFO,
        __file__,
        1,
        "https://account/blob/patient.pdf?sv=1&sig=secret",
        ("patient-name",),
        None,
    )
    assert NoPhiFilter().filter(record)
    assert record.args == ()
    assert record.msg == "Sensitive log message redacted"


def test_safe_log_includes_only_event_and_document_id(caplog) -> None:
    logger = logging.getLogger("safe-log-test")
    with caplog.at_level(logging.INFO):
        safe_log(logger, logging.INFO, "Processed.", "opaque-id")
    assert "opaque-id" in caplog.text
    assert "sig=" not in caplog.text

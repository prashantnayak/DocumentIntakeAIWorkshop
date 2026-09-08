from __future__ import annotations

import logging


class NoPhiFilter(logging.Filter):
    """Drops accidental arguments and query strings from application logs."""

    def filter(self, record: logging.LogRecord) -> bool:
        message = str(record.msg)
        if "?" in message or "sig=" in message.casefold():
            record.msg = "Sensitive log message redacted"
        elif record.args:
            record.msg = "Application event details redacted"
        record.args = ()
        return True


def configure_safe_logging() -> None:
    logger = logging.getLogger("intake")
    if not any(isinstance(item, NoPhiFilter) for item in logger.filters):
        logger.addFilter(NoPhiFilter())


def safe_log(logger: logging.Logger, level: int, event: str, document_id: str) -> None:
    logger.log(level, "%s DocumentId=%s" % (event, document_id))

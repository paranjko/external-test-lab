#!/usr/bin/env python3
"""Create, verify, and remove one collision-proof assurance assignment."""

import json
import os
import time


TELEGRAM_SIGNIFICANT_ID_LIMIT = 2**52


def run_probe(telegram_id, sla_ms):
    if telegram_id >= -TELEGRAM_SIGNIFICANT_ID_LIMIT:
        raise ValueError("assurance Telegram ID must be outside the valid Telegram ID range")
    if sla_ms <= 0:
        raise ValueError("assurance SLA must be positive")

    # Import only inside the container (or after a test installs a fake module).
    from bot import connection, issue, key_works

    db = connection()
    owns_synthetic_id = False
    payload = None
    try:
        existing = db.execute(
            "SELECT 1 FROM keys WHERE telegram_id = ?", (telegram_id,)
        ).fetchone()
        if existing:
            raise RuntimeError("synthetic assurance Telegram ID already exists")
        # From this point onward any row with this impossible Telegram ID was
        # created by this invocation and is therefore safe to remove.
        owns_synthetic_id = True
        started = time.monotonic()
        key, created = issue(db, telegram_id, renew=True)
        verified = bool(key and created and key_works(key))
        elapsed_ms = round((time.monotonic() - started) * 1000)
        payload = {
            "created": bool(created),
            "verified": verified,
            "elapsed_ms": elapsed_ms,
            "within_sla": elapsed_ms <= sla_ms,
        }
    finally:
        cleaned = False
        if owns_synthetic_id:
            db.execute("DELETE FROM keys WHERE telegram_id = ?", (telegram_id,))
            db.commit()
            cleaned = db.execute(
                "SELECT 1 FROM keys WHERE telegram_id = ?", (telegram_id,)
            ).fetchone() is None
        db.close()

    if not cleaned:
        raise RuntimeError("temporary assurance assignment was not cleaned")
    payload["temporary_assignment_cleaned"] = True
    return payload


def main():
    telegram_id = int(os.environ["GDC_ASSURANCE_TEMP_TELEGRAM_ID"])
    sla_ms = int(os.environ["GDC_ASSURANCE_SLA_MS"])
    print(json.dumps(run_probe(telegram_id, sla_ms), sort_keys=True))


if __name__ == "__main__":
    main()

# http_client.py (acceptance-tests/lib)
#
# A thin wrapper around `requests` that every check module uses instead
# of calling requests.get()/post() directly, so retry/backoff behavior
# (transient network blips, a node mid-reboot, Prometheus briefly
# unreachable during a drill) is handled in exactly one place instead of
# copy-pasted into eight check modules.
#
# -----------------------------------------------------
# Parameters:
#
# 1) max_attempts   - Total attempts before giving up (default 5).
# 2) base_delay     - Seconds before the first retry; doubles each
#    subsequent attempt (default 1.0s, so attempts land at
#    ~0s/1s/2s/4s/8s).
# 3) retry_on_status - HTTP status codes worth retrying (default: the
#    5xx range plus 429). 4xx other than 429 is treated as a real
#    failure, not transient, and returned immediately without retrying.
#
# -----------------------------------------------------
# Usage:
#
#   from lib.http_client import request_with_backoff
#   resp = request_with_backoff("GET", "http://.../fleet/shared", timeout=5)
#   resp.raise_for_status()
#
# -----------------------------------------------------
# Best Practices:
#
# - This is exponential backoff for TRANSIENT failures during a live
#   check (a node briefly unreachable, Prometheus mid-restart) -- it is
#   not a substitute for a check's own pass/fail judgment. Once a
#   response comes back (even an error one that isn't worth retrying),
#   return it to the caller and let the check itself decide PASS/FAIL.
# - A network error on the LAST attempt is re-raised, not swallowed --
#   callers should catch requests.exceptions.RequestException and turn it
#   into a report.failed(...) with the actual exception message.
#
# -----------------------------------------------------
# Author:
# - Sandip Gangdhar
# - GitHub: https://github.com/sandipgangdhar
#
# (c) Linode-NAT-Gateway (LNG) | Developed by Sandip Gangdhar | 2026
# -----------------------------------------------------
"""
Retry-with-exponential-backoff HTTP helper for the acceptance-test suite.

Every check module should call request_with_backoff() rather than
requests.get()/post() directly, so one retry policy covers the whole
suite instead of being reimplemented per check.
"""
from __future__ import annotations

import time

import requests

DEFAULT_RETRY_STATUS = {429, 500, 502, 503, 504}


def request_with_backoff(
    method: str,
    url: str,
    max_attempts: int = 5,
    base_delay: float = 1.0,
    retry_on_status: set[int] | None = None,
    **kwargs,
) -> requests.Response:
    retry_on_status = retry_on_status if retry_on_status is not None else DEFAULT_RETRY_STATUS
    last_exc: Exception | None = None

    for attempt in range(1, max_attempts + 1):
        try:
            resp = requests.request(method, url, **kwargs)
        except requests.exceptions.RequestException as exc:
            last_exc = exc
            if attempt == max_attempts:
                raise
            time.sleep(base_delay * (2 ** (attempt - 1)))
            continue

        if resp.status_code in retry_on_status and attempt < max_attempts:
            time.sleep(base_delay * (2 ** (attempt - 1)))
            continue

        return resp

    # Unreachable in practice (the loop above always returns or raises),
    # but keeps type checkers honest about the function's return type.
    assert last_exc is not None
    raise last_exc

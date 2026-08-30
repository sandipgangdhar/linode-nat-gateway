# __init__.py (acceptance-tests/lib)
#
# Marks lib/ as a regular Python package so check modules can
# `from lib.config import load_config`, `from lib.reporter import Reporter`,
# and `from lib.http_client import request_with_backoff` regardless of
# which directory run_acceptance_tests.py was invoked from. Carries no
# code of its own.
#
# -----------------------------------------------------
# Author:
# - Sandip Gangdhar
# - GitHub: https://github.com/sandipgangdhar
#
# (c) Linode-NAT-Gateway (LNG) | Developed by Sandip Gangdhar | 2026
# -----------------------------------------------------

# __init__.py (acceptance-tests/checks)
#
# Marks checks/ as a regular Python package. run_acceptance_tests.py
# discovers every check_*.py module in this directory automatically (by
# filename, sorted, so they run in a predictable order: roster/health
# first since every later check assumes the roster is reachable at all,
# then progressively more disruptive/slower checks). Carries no code of
# its own.
#
# -----------------------------------------------------
# Author:
# - Sandip Gangdhar
# - GitHub: https://github.com/sandipgangdhar
#
# (c) Linode-NAT-Gateway (LNG) | Developed by Sandip Gangdhar | 2026
# -----------------------------------------------------

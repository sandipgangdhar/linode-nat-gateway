#!/usr/bin/env bash
set -euo pipefail

ping -c1 -W1 1.1.1.1 >/dev/null || ping -c1 -W1 8.8.8.8 >/dev/null || exit 1
curl -m 2 -fsS https://www.google.com/generate_204 >/dev/null || exit 1

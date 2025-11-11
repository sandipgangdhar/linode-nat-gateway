#!/usr/bin/env bash
set -euo pipefail

GW=$(ip route | awk '/^default/ {print $3; exit}')
ping -c1 -W1 "$GW" >/dev/null || exit 1
ping -c1 -W1 1.1.1.1 >/dev/null || ping -c1 -W1 8.8.8.8 >/dev/null || exit 1
curl -m 2 -fsS https://www.google.com/generate_204 >/dev/null || exit 1

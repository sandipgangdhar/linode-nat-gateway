#!/usr/bin/env bash
peer="${1:?peer ip required}"
count="${2:-3}"
timeout="${3:-1}"
ping -I {{ ct_vlan_if }} -c "$count" -W "$timeout" "$peer" >/dev/null 2>&1

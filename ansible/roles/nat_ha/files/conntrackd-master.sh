#!/usr/bin/env bash
conntrackd -c flush cache >/dev/null 2>&1 || true
conntrackd -c setrole Primary

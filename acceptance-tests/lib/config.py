# config.py (acceptance-tests/lib)
#
# Loads and validates the acceptance-test config file (a copy of
# config.example.yaml, filled in with your actual deployment's endpoints,
# credentials, and drill targets) into a plain, dependency-light Config
# object every check module reads from. This is the one place that knows
# the on-disk YAML shape, so individual checks don't each re-implement
# their own parsing/validation.
#
# -----------------------------------------------------
# Parameters:
#
# 1) path - Path to a YAML config file matching config.example.yaml's
#    shape. See that file for every recognized key and what it's for.
#
# -----------------------------------------------------
# Usage:
#
#   from lib.config import load_config
#   cfg = load_config("config.yaml")
#   for pool_name, pool in cfg.pools.items():
#       ...
#
# - Config.pool(name) / Config.require(pool, *keys) are the two methods
#   check modules actually call -- require() raises MissingConfigError
#   with a message naming exactly which key is missing and from which
#   pool, so a check can catch it and SKIP with a clear reason rather
#   than crash the whole run over one unfilled-in optional field.
#
# -----------------------------------------------------
# Best Practices:
#
# - Never put real secrets (SSH key paths, etc.) in config.example.yaml
#   itself -- it ships with placeholder values only. Keep your real
#   config.yaml out of version control (see the repo .gitignore).
# - Add new pool-level keys here with a sensible default via .get() rather
#   than a bare [] lookup, so older config files don't break newer checks
#   outright -- prefer a graceful SKIP in the check itself.
#
# -----------------------------------------------------
# Author:
# - Sandip Gangdhar
# - GitHub: https://github.com/sandipgangdhar
#
# (c) Linode-NAT-Gateway (LNG) | Developed by Sandip Gangdhar | 2026
# -----------------------------------------------------
"""
Config loader for the LNG acceptance-test suite (acceptance-tests/).

Every check module receives the same parsed Config object and reads
whatever section it needs from it, via Config.pool()/Config.require() so
missing optional fields become a clean SKIP instead of a crash.
"""
from __future__ import annotations

import yaml
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any


class MissingConfigError(Exception):
    """Raised by Config.require() when a check's needed key isn't set.

    Callers (check modules) are expected to catch this specifically and
    turn it into a report.skipped(...) call -- an unfilled-in optional
    drill target (e.g. no ip_failover_drill block for a pool that doesn't
    use IP failover) is a SKIP, not a suite-wide FAIL.
    """


@dataclass
class Config:
    raw: dict[str, Any]
    control_plane: dict[str, Any] = field(default_factory=dict)
    ssh: dict[str, Any] = field(default_factory=dict)
    pools: dict[str, dict[str, Any]] = field(default_factory=dict)

    def pool(self, name: str) -> dict[str, Any]:
        if name not in self.pools:
            raise MissingConfigError(f"no pool named '{name}' in config (have: {list(self.pools)})")
        return self.pools[name]

    def require(self, section: dict[str, Any], *keys: str, context: str = "") -> tuple:
        """
        Fetch one or more keys from `section` (typically a pool dict, or
        cfg.control_plane), raising MissingConfigError naming exactly
        which key is absent if any are missing or blank. Returns a tuple
        matching the order of `keys` (unpack directly: `a, b = cfg.require(pool, "a", "b")`).
        """
        missing = [k for k in keys if not section.get(k)]
        if missing:
            where = f" for {context}" if context else ""
            raise MissingConfigError(f"missing required config key(s){where}: {', '.join(missing)}")
        return tuple(section[k] for k in keys)


def load_config(path: str) -> Config:
    raw = yaml.safe_load(Path(path).read_text()) or {}
    return Config(
        raw=raw,
        control_plane=raw.get("control_plane", {}) or {},
        ssh=raw.get("ssh", {}) or {},
        pools=raw.get("pools", {}) or {},
    )

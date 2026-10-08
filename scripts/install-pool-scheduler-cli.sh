#!/usr/bin/env bash
# install-pool-scheduler-cli.sh (scripts)
#
# Sets up a host to run the nightly pool-down/pool-up cron schedule for
# one or more pools, per docs/NAT-GATEWAY-DEFINITIVE-GUIDE.html "Schedule nightly power-down/up
# for a pool". This host does NOT need to be part of this project's own
# Terraform-managed infrastructure, and needs no VPC network reachability
# to any NAT node at all -- natctl_cli's pool-down/pool-up write their
# durable state straight to Object Storage and verify against the live
# Linode API directly (see natctl_cli.py's own module header comment,
# item 13), so the only two things this host ever needs are a Linode API
# token and an Object Storage key pair, both reachable over the public
# internet. Run this on whatever you already have available: a small
# dedicated instance, an existing ops box, a CI/CD runner with a
# scheduled pipeline -- anywhere that can run cron and keep two small
# files at rest.
#
# A dedicated, unprivileged system user (natctl-scheduler, no login
# shell) owns the installed binary, config, and credentials file --
# nothing here runs as root after this script itself finishes, and the
# crontab entry this script installs runs as that user too.
#
# Does NOT fetch pool definitions by hand -- the generated config.yaml
# points at this environment's own `pools_registry` Object Storage
# object (the same one Terraform writes and every real natctl daemon
# already reads every reconcile pass), so it can never drift from
# whatever pools actually exist. Only the credentials and the one
# secret the registry deliberately never carries (root_pass, needed by
# pool-up's own direct-provisioning fallback for a newly-created node)
# are supplied here.
#
# -----------------------------------------------------
# Usage:
#
# Interactively, with flags (credentials are prompted for if their
# corresponding --*-file flag is omitted -- never pass a secret as a
# bare command-line argument, which would leak it into shell history and
# `ps`):
#
#   sudo ./install-pool-scheduler-cli.sh \
#     --bucket lng-v0105-artifacts --region ap-south-1 \
#     --linode-token-file ~/.lng-linode-token \
#     --object-storage-access-key-file ~/.lng-os-access-key \
#     --object-storage-secret-key-file ~/.lng-os-secret-key \
#     --root-pass-file ~/.lng-root-pass \
#     --pool dedicated-duo --down-cron "0 23 * * *" --up-cron "0 7 * * *" \
#     --notify-webhook-url-file ~/.lng-notify-webhook-url
#
# Add --pool again (with its own --down-cron/--up-cron right after it)
# for each additional pool this host should schedule -- one host can
# drive any number of pools, each on its own schedule.
#
# --binary-url defaults to the latest natctl-cli GitHub Release asset
# for this account's own customer repo; pass your own URL (or
# --binary-path for an already-downloaded/locally-built binary) to pin a
# specific version instead.
#
# Re-run this script any time to change the schedule, rotate a
# credential, or add another --pool -- it is fully idempotent (safe to
# run repeatedly; each run replaces the previous config/crontab/
# credentials file in place, never duplicating a crontab entry).
#
# Optional failure notification: pass --notify-webhook-url (or
# --notify-webhook-url-file, same never-as-a-bare-argument convention as
# every other credential here, since a webhook URL often embeds its own
# secret path component) to have a failed pool-down/pool-up POST a short
# JSON failure report there. This exists because this host has no other
# built-in way to tell a human a scheduled run failed overnight -- cron's
# own failure signal is a mail to a local mailbox nobody reads, if even
# that's configured, and the log file in /var/lib/natctl-scheduler is
# only ever seen by someone who already knows to go look. Works with any
# endpoint that accepts a POST of {"text": "..."} (Slack/Mattermost
# incoming webhooks accept this directly; point it at a small adapter
# first for a receiver that expects a different shape). Off by default --
# omit both flags and nothing is ever sent.
#
# -----------------------------------------------------
# Author:
# - Sandip Gangdhar
# - GitHub: https://github.com/sandipgangdhar
#
# (c) Linode-NAT-Gateway (LNG) | Developed by Sandip Gangdhar | 2026
# -----------------------------------------------------
set -euo pipefail

# ---- defaults ---------------------------------------------------------

INSTALL_DIR="/opt/natctl-scheduler"
CONFIG_DIR="/etc/natctl-scheduler"
STATE_DIR="/var/lib/natctl-scheduler"
CRON_FILE="/etc/cron.d/natctl-pool-scheduler"
SERVICE_USER="natctl-scheduler"
BINARY_URL="https://github.com/sandipgangdhar/linode-nat-gateway/releases/latest/download/natctl-cli"
BINARY_PATH=""
BUCKET=""
REGION=""
LINODE_TOKEN_FILE=""
ACCESS_KEY_FILE=""
SECRET_KEY_FILE=""
ROOT_PASS_FILE=""
POOLS=()
DOWN_CRONS=()
UP_CRONS=()
DOWN_REASON="nightly schedule"
UP_REASON="morning schedule"
WAIT_FLAG="--wait"
TIMEOUT_SECONDS="600"
FORCE_DIRECT_PROVISION="false"
NOTIFY_WEBHOOK_URL=""
NOTIFY_WEBHOOK_URL_FILE=""

# ---- arg parsing --------------------------------------------------------

print_usage() {
  sed -n '1,77p' "$0" | sed 's/^# \{0,1\}//'
}

CURRENT_POOL=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --bucket) BUCKET="$2"; shift 2 ;;
    --region) REGION="$2"; shift 2 ;;
    --linode-token-file) LINODE_TOKEN_FILE="$2"; shift 2 ;;
    --object-storage-access-key-file) ACCESS_KEY_FILE="$2"; shift 2 ;;
    --object-storage-secret-key-file) SECRET_KEY_FILE="$2"; shift 2 ;;
    --root-pass-file) ROOT_PASS_FILE="$2"; shift 2 ;;
    --binary-url) BINARY_URL="$2"; shift 2 ;;
    --binary-path) BINARY_PATH="$2"; shift 2 ;;
    --pool)
      POOLS+=("$2")
      DOWN_CRONS+=("0 23 * * *")
      UP_CRONS+=("0 7 * * *")
      CURRENT_POOL="$2"
      shift 2
      ;;
    --down-cron)
      [[ -n "$CURRENT_POOL" ]] || { echo "--down-cron must follow a --pool" >&2; exit 1; }
      DOWN_CRONS[${#DOWN_CRONS[@]}-1]="$2"
      shift 2
      ;;
    --up-cron)
      [[ -n "$CURRENT_POOL" ]] || { echo "--up-cron must follow a --pool" >&2; exit 1; }
      UP_CRONS[${#UP_CRONS[@]}-1]="$2"
      shift 2
      ;;
    --down-reason) DOWN_REASON="$2"; shift 2 ;;
    --up-reason) UP_REASON="$2"; shift 2 ;;
    --timeout-seconds) TIMEOUT_SECONDS="$2"; shift 2 ;;
    --no-wait) WAIT_FLAG=""; shift ;;
    --force-direct-provision) FORCE_DIRECT_PROVISION="true"; shift ;;
    --notify-webhook-url) NOTIFY_WEBHOOK_URL="$2"; shift 2 ;;
    --notify-webhook-url-file) NOTIFY_WEBHOOK_URL_FILE="$2"; shift 2 ;;
    -h|--help) print_usage; exit 0 ;;
    *) echo "Unknown argument: $1" >&2; print_usage; exit 1 ;;
  esac
done

if [[ "$(id -u)" -ne 0 ]]; then
  echo "Must run as root (creates a system user, installs to /opt and /etc, writes a crontab)." >&2
  exit 1
fi
if [[ -z "$BUCKET" || -z "$REGION" ]]; then
  echo "--bucket and --region are required (this environment's Object Storage bucket/region)." >&2
  exit 1
fi
if [[ ${#POOLS[@]} -eq 0 ]]; then
  echo "At least one --pool is required." >&2
  exit 1
fi

# ---- credential inputs (prompted if not given as a --*-file; never
# accepted as a bare argument, and never echoed back) --------------------

read_secret_file_or_prompt() {
  local file="$1" prompt="$2"
  if [[ -n "$file" ]]; then
    [[ -f "$file" ]] || { echo "No such file: $file" >&2; exit 1; }
    cat "$file"
    return
  fi
  local value
  read -rsp "$prompt: " value
  echo >&2
  printf '%s' "$value"
}

LINODE_TOKEN="$(read_secret_file_or_prompt "$LINODE_TOKEN_FILE" "Linode API token")"
OS_ACCESS_KEY="$(read_secret_file_or_prompt "$ACCESS_KEY_FILE" "Object Storage access key")"
OS_SECRET_KEY="$(read_secret_file_or_prompt "$SECRET_KEY_FILE" "Object Storage secret key")"
ROOT_PASS="$(read_secret_file_or_prompt "$ROOT_PASS_FILE" "Fleet root_pass (used only if pool-up has to provision a node directly)")"

# Notification webhook is optional and never prompted for -- omitting
# both flags just leaves it unset, and the generated run-scheduled-
# action.sh wrapper (below) treats an unset NOTIFY_WEBHOOK_URL as
# "feature off", not an error.
if [[ -n "$NOTIFY_WEBHOOK_URL_FILE" ]]; then
  [[ -f "$NOTIFY_WEBHOOK_URL_FILE" ]] || { echo "No such file: $NOTIFY_WEBHOOK_URL_FILE" >&2; exit 1; }
  NOTIFY_WEBHOOK_URL="$(cat "$NOTIFY_WEBHOOK_URL_FILE")"
fi

# ---- system user --------------------------------------------------------

if ! id "$SERVICE_USER" >/dev/null 2>&1; then
  useradd --system --no-create-home --shell /usr/sbin/nologin "$SERVICE_USER"
  echo "Created system user $SERVICE_USER."
fi

mkdir -p "$INSTALL_DIR" "$CONFIG_DIR" "$STATE_DIR"
chown "$SERVICE_USER:$SERVICE_USER" "$INSTALL_DIR" "$CONFIG_DIR" "$STATE_DIR"
chmod 750 "$INSTALL_DIR" "$CONFIG_DIR"
chmod 750 "$STATE_DIR"

# ---- natctl-cli binary --------------------------------------------------

BINARY_DEST="$INSTALL_DIR/natctl-cli"
if [[ -n "$BINARY_PATH" ]]; then
  cp "$BINARY_PATH" "$BINARY_DEST"
else
  echo "Fetching natctl-cli from $BINARY_URL ..."
  curl -fsSL -o "$BINARY_DEST" "$BINARY_URL"
fi
chmod 755 "$BINARY_DEST"
chown "$SERVICE_USER:$SERVICE_USER" "$BINARY_DEST"

# ---- credentials file (0600, never world/group readable, owned by the
# service user only) ------------------------------------------------------

ENV_FILE="$CONFIG_DIR/env"
umask 177
NOTIFY_ENABLED="false"
[[ -n "$NOTIFY_WEBHOOK_URL" ]] && NOTIFY_ENABLED="true"
cat > "$ENV_FILE" <<EOF
LINODE_TOKEN=$LINODE_TOKEN
NATCTL_OBJECT_STORAGE_ACCESS_KEY=$OS_ACCESS_KEY
NATCTL_OBJECT_STORAGE_SECRET_KEY=$OS_SECRET_KEY
NOTIFY_WEBHOOK_URL=$NOTIFY_WEBHOOK_URL
EOF
umask 022
chmod 600 "$ENV_FILE"
chown "$SERVICE_USER:$SERVICE_USER" "$ENV_FILE"
unset LINODE_TOKEN OS_ACCESS_KEY OS_SECRET_KEY NOTIFY_WEBHOOK_URL NOTIFY_WEBHOOK_URL_FILE

# ---- minimal natctl.yaml -- no pool fields hand-authored here at all;
# pools_registry below pulls the real, current pool list straight from
# this environment's own Object Storage, the same object every real
# natctl daemon already reads every reconcile pass. root_pass is the one
# field the registry deliberately never carries (it holds no secrets) --
# only used if pool-up's direct-provisioning fallback ever has to create
# a brand-new node from a fully-empty pool. Rendered via Python (not bash
# heredoc interpolation) so a root_pass containing a quote/colon/
# backslash can never break the YAML or be misparsed -- json.dumps()
# produces a valid YAML flow-scalar string for any Python str, including
# one with embedded special characters. Secrets are passed through the
# environment, never as argv (which `ps` can see from other users on a
# shared/multi-tenant host). -----------------------------------------

CONFIG_FILE="$CONFIG_DIR/config.yaml"
NATCTL_SCHEDULER_BUCKET="$BUCKET" \
NATCTL_SCHEDULER_REGION="$REGION" \
NATCTL_SCHEDULER_CACHE_PATH="$STATE_DIR/pools-registry.cache.json" \
NATCTL_SCHEDULER_ROOT_PASS="$ROOT_PASS" \
NATCTL_SCHEDULER_CONFIG_FILE="$CONFIG_FILE" \
python3 <<'PYEOF'
import json
import os

root_pass = os.environ["NATCTL_SCHEDULER_ROOT_PASS"]
config = f"""\
# Generated by install-pool-scheduler-cli.sh -- re-run that script to
# change anything here rather than hand-editing this file, which it
# will overwrite on the next run anyway.
root_pass: {json.dumps(root_pass)}
linode:
  token: null  # resolved from LINODE_TOKEN in this directory's env file
leader_election:
  object_storage_access_key: null  # resolved from NATCTL_OBJECT_STORAGE_ACCESS_KEY
  object_storage_secret_key: null  # resolved from NATCTL_OBJECT_STORAGE_SECRET_KEY
pools_registry:
  bucket: {json.dumps(os.environ["NATCTL_SCHEDULER_BUCKET"])}
  s3_region: {json.dumps(os.environ["NATCTL_SCHEDULER_REGION"])}
  cache_path: {json.dumps(os.environ["NATCTL_SCHEDULER_CACHE_PATH"])}
"""
path = os.environ["NATCTL_SCHEDULER_CONFIG_FILE"]
fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
with os.fdopen(fd, "w") as f:
    f.write(config)
PYEOF
unset ROOT_PASS
chown "$SERVICE_USER:$SERVICE_USER" "$CONFIG_FILE"

# ---- failure-notification helper (stdlib-only Python, no urllib3/
# requests dependency needed on this host) -- a no-op whenever
# NOTIFY_WEBHOOK_URL isn't set, so it's always installed but only ever
# does anything when that's configured. --------------------------------

NOTIFY_SCRIPT="$INSTALL_DIR/notify-failure.py"
cat > "$NOTIFY_SCRIPT" <<'PYEOF'
#!/usr/bin/env python3
# Generated by install-pool-scheduler-cli.sh -- do not hand-edit, re-run
# that script instead. Best-effort POST of a short failure report to
# NOTIFY_WEBHOOK_URL (read from the environment -- run-scheduled-
# action.sh already sources the credentials env file before calling
# this). Never raises and always exits 0: a broken notification must
# never mask the real pool-down/pool-up exit code the caller already
# captured, and must never itself become a second thing that silently
# fails overnight.
import json
import os
import socket
import sys
import time
import urllib.request


def main() -> int:
    if len(sys.argv) != 5:
        print("usage: notify-failure.py <pool> <action> <exit_code> <log_file>", file=sys.stderr)
        return 0
    pool, action, exit_code, log_file = sys.argv[1:5]
    webhook_url = os.environ.get("NOTIFY_WEBHOOK_URL", "").strip()
    if not webhook_url:
        return 0
    try:
        with open(log_file, "rb") as f:
            f.seek(0, os.SEEK_END)
            size = f.tell()
            f.seek(max(0, size - 2000))
            log_tail = f.read().decode("utf-8", errors="replace")
    except OSError as exc:
        log_tail = f"(could not read log file: {exc})"
    text = (
        f"natctl pool-scheduler FAILURE: pool={pool} action={action} "
        f"exit_code={exit_code} host={socket.gethostname()} "
        f"at={time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime())}\n"
        f"log tail:\n{log_tail}"
    )
    payload = json.dumps({"text": text}).encode("utf-8")
    req = urllib.request.Request(
        webhook_url, data=payload, headers={"Content-Type": "application/json"}, method="POST"
    )
    try:
        with urllib.request.urlopen(req, timeout=10) as resp:
            resp.read()
    except Exception as exc:  # best-effort only -- see module docstring
        print(f"notify webhook POST failed: {exc}", file=sys.stderr)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
PYEOF
chmod 750 "$NOTIFY_SCRIPT"
chown "$SERVICE_USER:$SERVICE_USER" "$NOTIFY_SCRIPT"

# ---- per-invocation wrapper -- cron calls this instead of natctl-cli
# directly, so the logging + on-failure notification logic lives in one
# generated, re-run-to-update file rather than being hand-assembled into
# each crontab line. DOWN_REASON/UP_REASON/FORCE_DIRECT_PROVISION are
# fixed per installation (same for every scheduled pool, matching this
# script's own existing global-flag design above), so they're baked in
# here at generation time; only the pool name and down/up action vary
# per cron line, passed as this wrapper's own two arguments. -----------

RUN_SCRIPT="$INSTALL_DIR/run-scheduled-action.sh"
DOWN_REASON_Q=$(printf '%q' "$DOWN_REASON")
UP_REASON_Q=$(printf '%q' "$UP_REASON")
FORCE_FLAG_ARG=""
[[ "$FORCE_DIRECT_PROVISION" == "true" ]] && FORCE_FLAG_ARG="--force-direct-provision"

cat > "$RUN_SCRIPT" <<EOF
#!/usr/bin/env bash
# Generated by install-pool-scheduler-cli.sh -- do not hand-edit, re-run
# that script instead. Runs one pool-down/pool-up invocation for the
# pool named on the command line, logs it to $STATE_DIR/<pool>.log, and
# -- whenever that invocation exits non-zero -- hands off to
# notify-failure.py, which POSTs a short report to NOTIFY_WEBHOOK_URL
# when one is configured. This exists because cron's own failure signal
# (a mail to a local mailbox nobody reads, if even that's configured) is
# not a reliable way to learn a scheduled pool failed to come back
# before the morning's traffic arrives.
set -uo pipefail

ACTION="\$1"   # down | up
POOL="\$2"

set -a
. "$ENV_FILE"
set +a

LOG_FILE="$STATE_DIR/\$POOL.log"

case "\$ACTION" in
  down) REASON=$DOWN_REASON_Q; EXTRA_FLAG="" ;;
  up)   REASON=$UP_REASON_Q;   EXTRA_FLAG="$FORCE_FLAG_ARG" ;;
  *) echo "Unknown action: \$ACTION" >&2; exit 1 ;;
esac

{
  echo "=== \$(date -u +%Y-%m-%dT%H:%M:%SZ) pool-\$ACTION \$POOL ==="
  "$BINARY_DEST" --config "$CONFIG_FILE" "pool-\$ACTION" --pool "\$POOL" --reason "\$REASON" $WAIT_FLAG --timeout-seconds $TIMEOUT_SECONDS \$EXTRA_FLAG
} >> "\$LOG_FILE" 2>&1
EXIT_CODE=\$?

if [[ "\$EXIT_CODE" -ne 0 ]]; then
  python3 "$NOTIFY_SCRIPT" "\$POOL" "\$ACTION" "\$EXIT_CODE" "\$LOG_FILE" >> "\$LOG_FILE" 2>&1
fi

exit "\$EXIT_CODE"
EOF
chmod 750 "$RUN_SCRIPT"
chown "$SERVICE_USER:$SERVICE_USER" "$RUN_SCRIPT"

# ---- crontab -------------------------------------------------------------
# One /etc/cron.d file, fully regenerated each run (idempotent -- never
# appends a duplicate entry). Each pool gets its own down/up line, both
# delegating to the generated run-scheduled-action.sh wrapper above.

{
  echo "# Generated by install-pool-scheduler-cli.sh -- do not hand-edit, re-run that script instead."
  echo "SHELL=/bin/bash"
  echo "PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
  for i in "${!POOLS[@]}"; do
    pool="${POOLS[$i]}"
    down_cron="${DOWN_CRONS[$i]}"
    up_cron="${UP_CRONS[$i]}"
    echo "$down_cron $SERVICE_USER $RUN_SCRIPT down $pool"
    echo "$up_cron $SERVICE_USER $RUN_SCRIPT up $pool"
  done
} > "$CRON_FILE"
chmod 644 "$CRON_FILE"

echo
echo "Installed. Scheduled pools:"
for i in "${!POOLS[@]}"; do
  echo "  ${POOLS[$i]}: down at '${DOWN_CRONS[$i]}', up at '${UP_CRONS[$i]}' (logs: $STATE_DIR/${POOLS[$i]}.log)"
done
echo
if [[ "$NOTIFY_ENABLED" == "true" ]]; then
  echo "Failure notifications: enabled -- a failed pool-down/up POSTs a report to the configured webhook."
else
  echo "Failure notifications: disabled -- re-run with --notify-webhook-url (or --notify-webhook-url-file) to enable."
  echo "Without it, a failed scheduled run is only visible in $STATE_DIR/<pool>.log and cron's own mail, if configured."
fi
echo
echo "Verify immediately with a dry run as the service user, e.g.:"
echo "  sudo -u $SERVICE_USER bash -c 'set -a; . $ENV_FILE; set +a; $BINARY_DEST --config $CONFIG_FILE status'"
echo
echo "Re-run this script any time to change the schedule, rotate a credential, or add another --pool."

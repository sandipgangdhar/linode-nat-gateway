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
#     --pool dedicated-duo --down-cron "0 23 * * *" --up-cron "0 7 * * *"
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

# ---- arg parsing --------------------------------------------------------

print_usage() {
  sed -n '1,65p' "$0" | sed 's/^# \{0,1\}//'
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
cat > "$ENV_FILE" <<EOF
LINODE_TOKEN=$LINODE_TOKEN
NATCTL_OBJECT_STORAGE_ACCESS_KEY=$OS_ACCESS_KEY
NATCTL_OBJECT_STORAGE_SECRET_KEY=$OS_SECRET_KEY
EOF
umask 022
chmod 600 "$ENV_FILE"
chown "$SERVICE_USER:$SERVICE_USER" "$ENV_FILE"
unset LINODE_TOKEN OS_ACCESS_KEY OS_SECRET_KEY

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

# ---- crontab -------------------------------------------------------------
# One /etc/cron.d file, fully regenerated each run (idempotent -- never
# appends a duplicate entry). Each pool gets its own down/up line.

{
  echo "# Generated by install-pool-scheduler-cli.sh -- do not hand-edit, re-run that script instead."
  echo "SHELL=/bin/bash"
  echo "PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
  for i in "${!POOLS[@]}"; do
    pool="${POOLS[$i]}"
    down_cron="${DOWN_CRONS[$i]}"
    up_cron="${UP_CRONS[$i]}"
    force_flag=""
    [[ "$FORCE_DIRECT_PROVISION" == "true" ]] && force_flag=" --force-direct-provision"
    echo "$down_cron $SERVICE_USER set -a; . $ENV_FILE; set +a; $BINARY_DEST --config $CONFIG_FILE pool-down --pool $pool --reason \"$DOWN_REASON\" $WAIT_FLAG --timeout-seconds $TIMEOUT_SECONDS >> $STATE_DIR/$pool.log 2>&1"
    echo "$up_cron $SERVICE_USER set -a; . $ENV_FILE; set +a; $BINARY_DEST --config $CONFIG_FILE pool-up --pool $pool --reason \"$UP_REASON\" $WAIT_FLAG --timeout-seconds $TIMEOUT_SECONDS$force_flag >> $STATE_DIR/$pool.log 2>&1"
  done
} > "$CRON_FILE"
chmod 644 "$CRON_FILE"

echo
echo "Installed. Scheduled pools:"
for i in "${!POOLS[@]}"; do
  echo "  ${POOLS[$i]}: down at '${DOWN_CRONS[$i]}', up at '${UP_CRONS[$i]}' (logs: $STATE_DIR/${POOLS[$i]}.log)"
done
echo
echo "Verify immediately with a dry run as the service user, e.g.:"
echo "  sudo -u $SERVICE_USER bash -c 'set -a; . $ENV_FILE; set +a; $BINARY_DEST --config $CONFIG_FILE status'"
echo
echo "Re-run this script any time to change the schedule, rotate a credential, or add another --pool."

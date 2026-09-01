#!/usr/bin/env bash
# install-nat-client.sh (scripts)
#
# Turns any existing Linode into a client of this NAT gateway fleet:
# sets a persistent static address on its VLAN interface, fetches the
# compiled client-agent binary from your artifacts bucket, and installs
# it as a systemd service that manages ECMP routing across every healthy
# node in the pool -- the same mechanism Terraform's client-fleet module
# wires up automatically for "vlan_only"/"vpc_vlan" client_groups
# (ansible/cloud-init/client-node.yaml.tftpl), packaged here as a
# standalone script for a server that already exists outside Terraform.
#
# Does NOT attach the VLAN interface itself -- that's a Linode
# account-level action (Cloud Manager, or `linode-cli linodes
# interface-add --vlan.vlan_label <label> --vlan.ipam_address <cidr>`,
# power the instance off first if replacing an existing interface). This
# script only configures what's already attached.
#
# -----------------------------------------------------
# Two ways to run this:
#
# 1) MANUALLY, on an already-running server, as root, with flags. No
#    internet access needed on this server -- client-agent is fetched
#    over the roster connection itself (see --artifact-base-url below):
#
#    ./install-nat-client.sh \
#      --roster-url http://10.60.32.20:8099/fleet/shared \
#      --vlan-ip 192.168.100.251/22
#
# 2) As LINODE USER DATA (Cloud Manager "Add-ons" tab at create time, or
#    `linode-cli linodes rebuild --metadata.user_data`), so a fresh
#    instance configures itself at first boot with no manual step at
#    all. User-data scripts run with no arguments, so set the same
#    values as environment variables INSTEAD of flags, exported right
#    after the shebang line, then paste the rest of this file below
#    them:
#
#    #!/usr/bin/env bash
#    export LNG_ROSTER_URL="http://10.60.32.20:8099/fleet/shared"
#    export LNG_VLAN_IP="192.168.100.251/22"
#    # ... paste the rest of install-nat-client.sh's body from the
#    # "set -euo pipefail" line down ...
#
#    The instance still needs its VLAN interface attached BEFORE first
#    boot (set that up wherever you create the instance -- Cloud
#    Manager, Terraform, `linode-cli linodes create`) -- user-data alone
#    can't attach a network interface to itself.
#
# -----------------------------------------------------
# Parameters (flag / equivalent env var):
#
# 1) --roster-url <url> / LNG_ROSTER_URL (required)
#      natctl's roster URL for the pool this client belongs to, e.g.
#      http://<nat-node-vpc-ip>:8099/fleet/<pool-name>. Must be reachable
#      from wherever this script runs -- if it hangs, check the NAT
#      node's own Cloud Firewall CIDR scoping for port 8099 before
#      assuming client-agent is broken (a client on the VPC's wrong
#      subnet is a real, silent way for this to fail -- see
#      docs/ARCHITECTURE.md's VPC/subnet notes).
#
# 2) --vlan-ip <cidr> / LNG_VLAN_IP (required)
#      This instance's own static address on the pool's VLAN, e.g.
#      192.168.100.251/22. Must not collide with any floor/elastic node
#      or another client on the same VLAN -- there is no reservation
#      system for manually-attached clients like this one, unlike
#      Terraform's client_groups static_vlan_slot mechanism, so check
#      collisions yourself (`linode-cli vlans list`, cross-referenced
#      against each member's ipam_address) before picking one.
#
# 3) --artifact-base-url <url> / LNG_ARTIFACT_BASE_URL (optional)
#      DEFAULT BEHAVIOR (no flag needed): client-agent is fetched from
#      natctl's own roster API -- GET <roster origin>/agents/client-agent
#      -- derived automatically from --roster-url by stripping its path.
#      This is deliberate, not a shortcut: a "vlan_only"/"vpc_vlan" client
#      has NO internet path of its own until client-agent itself brings
#      one up (that's the entire point of those modes), so it can never
#      reach an internet-facing Object Storage URL directly -- confirmed
#      live, 2026-09-01 (a real DNS/routing failure against the bucket
#      URL on a genuinely private-only test client). natctl itself
#      fetches the binary from Object Storage once at ITS OWN startup
#      (it has real internet via its own public IP) and re-serves it
#      locally over the same roster host/port -- see
#      controller/natctl/api.py's GET /agents/client-agent (dev repo) and
#      terraform/environments/example/main.tf's client_agent_bin_url
#      wiring. Only pass this flag to override with a direct Object
#      Storage fetch instead -- e.g. for a "public_vlan"-mode client that
#      already has its own internet path and would rather not depend on
#      natctl's serving endpoint being configured/reachable. If given:
#      base URL of your artifacts bucket, WITHOUT a trailing slash, e.g.
#      https://lng-artifacts.in-maa-1.linodeobjects.com/lng-artifacts
#      (matches terraform/modules/artifacts main.tf's key layout --
#      fetches "<base>/bin/client-agent").
#
# 4) --vlan-iface <name> / LNG_VLAN_IFACE (optional)
#      Which network interface is the VLAN one. If omitted, this script
#      auto-detects it as the first non-loopback interface with no IPv4
#      address currently assigned (Linode auto-configures VPC interfaces
#      via DHCP at boot but never does this for VLAN interfaces -- see
#      docs/ARCHITECTURE.md -- so an addressless interface is a reliable
#      signal on a freshly-attached instance). Auto-detection can guess
#      wrong on an instance with other unconfigured interfaces for
#      unrelated reasons -- the script prints what it picked before
#      using it; pass this flag explicitly if that's ever not right.
#
# 5) --poll-interval <seconds> / LNG_ROSTER_POLL_INTERVAL (optional, default 30)
# 6) --health-probe-interval <seconds> / LNG_HEALTH_PROBE_INTERVAL (optional, default 3)
# 7) --health-probe-timeout <seconds> / LNG_HEALTH_PROBE_TIMEOUT (optional, default 1.5)
#      Match client-agent/lng-client-agent.env.example's own defaults --
#      only override if you've tuned these elsewhere in your fleet.
#
# -----------------------------------------------------
# Best Practices:
#
# - Safe to re-run -- every step here is idempotent (overwrites its own
#   config files, restarts rather than double-starts services).
# - After running, confirm with:
#     ip route                              # ECMP route via the VLAN
#     journalctl -u lng-client-agent -f     # should show nodes healthy
#     curl -s https://ifconfig.me           # should print a NAT node's
#                                            # public IP, not this host's
# - This script installs client-agent, which manages the default route
#   dynamically -- it will NOT work as a "just this one static route"
#   substitute the way a hand-added `ip route add` would. If you only
#   want a one-off connectivity test against a single node, a manual
#   `ip route add <dest> via <nat-node-vlan-ip> dev <iface>` is simpler
#   and this script is unnecessary overhead for that narrower case.
#
# -----------------------------------------------------
# Author:
# - Sandip Gangdhar
# - GitHub: https://github.com/sandipgangdhar
#
# (c) Linode-NAT-Gateway (LNG) | Developed by Sandip Gangdhar | 2026
# -----------------------------------------------------

set -euo pipefail

while [[ $# -gt 0 ]]; do
  case "$1" in
    --roster-url) LNG_ROSTER_URL="$2"; shift 2 ;;
    --vlan-ip) LNG_VLAN_IP="$2"; shift 2 ;;
    --artifact-base-url) LNG_ARTIFACT_BASE_URL="$2"; shift 2 ;;
    --vlan-iface) LNG_VLAN_IFACE="$2"; shift 2 ;;
    --poll-interval) LNG_ROSTER_POLL_INTERVAL="$2"; shift 2 ;;
    --health-probe-interval) LNG_HEALTH_PROBE_INTERVAL="$2"; shift 2 ;;
    --health-probe-timeout) LNG_HEALTH_PROBE_TIMEOUT="$2"; shift 2 ;;
    *) echo "Unknown arg: $1" >&2; exit 1 ;;
  esac
done

: "${LNG_ROSTER_URL:?--roster-url (or LNG_ROSTER_URL) is required, e.g. http://10.60.32.20:8099/fleet/shared}"
: "${LNG_VLAN_IP:?--vlan-ip (or LNG_VLAN_IP) is required, e.g. 192.168.100.251/22}"
# LNG_ARTIFACT_BASE_URL is intentionally optional now -- see the
# --artifact-base-url parameter comment above. Left unset, client-agent
# is fetched from natctl's own roster API instead of an internet-facing
# Object Storage URL, which is what actually works for a private-only
# ("vlan_only"/"vpc_vlan") client (confirmed live, 2026-09-01, against a
# genuinely internet-less test client -- the bucket-URL fetch just hung
# on DNS resolution, exactly as expected for a host with no route out).
LNG_ROSTER_POLL_INTERVAL="${LNG_ROSTER_POLL_INTERVAL:-30}"
LNG_HEALTH_PROBE_INTERVAL="${LNG_HEALTH_PROBE_INTERVAL:-3}"
LNG_HEALTH_PROBE_TIMEOUT="${LNG_HEALTH_PROBE_TIMEOUT:-1.5}"

if [[ "$(id -u)" -ne 0 ]]; then
  echo "Must run as root." >&2
  exit 1
fi

# 1. Identify the VLAN interface if not given explicitly -- the first
#    non-loopback interface with no IPv4 address, since Linode never
#    auto-assigns one to a VLAN interface (unlike VPC, which gets DHCP).
if [[ -z "${LNG_VLAN_IFACE:-}" ]]; then
  for iface in $(ip -o link show | awk -F': ' '{print $2}' | grep -v '^lo$'); do
    if ! ip -4 -o addr show dev "$iface" | grep -q inet; then
      LNG_VLAN_IFACE="$iface"
      break
    fi
  done
  : "${LNG_VLAN_IFACE:?Could not auto-detect the VLAN interface (every interface already has an IPv4 address) -- pass --vlan-iface explicitly.}"
  echo "Auto-detected VLAN interface: $LNG_VLAN_IFACE (no IPv4 address was configured on it yet)"
fi

VLAN_PREFIX="${LNG_VLAN_IP#*/}"
if [[ "$VLAN_PREFIX" == "$LNG_VLAN_IP" ]]; then
  echo "--vlan-ip must include a prefix, e.g. 192.168.100.251/22" >&2
  exit 1
fi
VLAN_ADDR="${LNG_VLAN_IP%%/*}"

# 2. Persistent static address on the VLAN interface. The "00-" filename
#    prefix is deliberate, not cosmetic -- Akamai's own network stage
#    writes a competing "05-eth<N>.network" first, and systemd-networkd
#    applies only the lexically-first match (same reasoning as this
#    project's own ansible/cloud-init/client-node.yaml.tftpl).
mkdir -p /etc/systemd/network
cat >/etc/systemd/network/00-lng-vlan.network <<EOF
[Match]
Name=${LNG_VLAN_IFACE}

[Network]
Address=${VLAN_ADDR}/${VLAN_PREFIX}
EOF
systemctl restart systemd-networkd
ip addr add "${LNG_VLAN_IP}" dev "${LNG_VLAN_IFACE}" 2>/dev/null || true
ip link set "${LNG_VLAN_IFACE}" up

# 3. Fetch the compiled client-agent binary. python3, not curl -- every
#    Ubuntu cloud image guarantees python3 (cloud-init itself needs it),
#    but curl needs an apt-get install, which needs internet access this
#    host may not have yet if its only path out is the NAT gateway this
#    script hasn't finished configuring (same chicken-and-egg reasoning
#    as ansible/cloud-init/client-node.yaml.tftpl).
#
#    Default source: natctl's own roster API (same host/port as
#    LNG_ROSTER_URL, just a different path) -- reachable over VPC/VLAN
#    with no internet needed, since natctl already fetched this binary
#    itself at its own startup and re-serves it locally. Only use the
#    Object Storage bucket directly if LNG_ARTIFACT_BASE_URL was
#    explicitly passed (a client that already has its own internet path
#    and would rather not depend on natctl's serving endpoint).
if [[ -n "${LNG_ARTIFACT_BASE_URL:-}" ]]; then
  CLIENT_AGENT_URL="${LNG_ARTIFACT_BASE_URL}/bin/client-agent"
else
  ROSTER_ORIGIN="$(printf '%s' "${LNG_ROSTER_URL}" | sed -E 's#(https?://[^/]+).*#\1#')"
  CLIENT_AGENT_URL="${ROSTER_ORIGIN}/agents/client-agent"
fi
echo "Fetching client-agent from: ${CLIENT_AGENT_URL}"

mkdir -p /opt/lng-client-agent
python3 -c "
import urllib.request
urllib.request.urlretrieve('${CLIENT_AGENT_URL}', '/opt/lng-client-agent/client-agent')
"
chmod +x /opt/lng-client-agent/client-agent

# 4. Config.
mkdir -p /etc/lng-client-agent
cat >/etc/lng-client-agent/env <<EOF
NATCTL_ROSTER_URL=${LNG_ROSTER_URL}
LNG_PRIVATE_IFACE=${LNG_VLAN_IFACE}
LNG_ROSTER_POLL_INTERVAL=${LNG_ROSTER_POLL_INTERVAL}
LNG_HEALTH_PROBE_INTERVAL=${LNG_HEALTH_PROBE_INTERVAL}
LNG_HEALTH_PROBE_TIMEOUT=${LNG_HEALTH_PROBE_TIMEOUT}
LNG_DRY_RUN=false
EOF

# 5. systemd unit -- static, non-secret content, embedded directly
#    rather than fetched (matches client-agent/lng-client-agent.service
#    in this repo and the identical reasoning in
#    ansible/cloud-init/client-node.yaml.tftpl).
cat >/etc/systemd/system/lng-client-agent.service <<'EOF'
[Unit]
Description=LNG client-side ECMP routing agent (compiled binary)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
EnvironmentFile=/etc/lng-client-agent/env
ExecStart=/opt/lng-client-agent/client-agent
Restart=on-failure
RestartSec=2
User=root
AmbientCapabilities=CAP_NET_ADMIN

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable --now lng-client-agent

echo "Done. client-agent installed and started on ${LNG_VLAN_IFACE} (${LNG_VLAN_IP})."
echo "Verify with:"
echo "  ip route"
echo "  journalctl -u lng-client-agent -f"
echo "  curl -s https://ifconfig.me"

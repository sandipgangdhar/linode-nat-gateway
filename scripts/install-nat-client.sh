#!/usr/bin/env bash
# install-nat-client.sh (scripts)
#
# Sets up NAT routing on an existing Linode that already has a static
# VLAN address applied -- the second of two separate steps for turning a
# server into a NAT gateway client (see configure-vlan-address.sh for
# the first: applying that address in the first place). If this
# instance doesn't already have a working default route of its own,
# fetches the compiled client-agent binary from your artifacts bucket
# and installs it as a systemd service that manages ECMP routing across
# every healthy node in the pool. An instance that already has its own
# working path out (a public IP, or a VPC interface with 1:1 NAT) is
# left alone by default, since there'd be nothing for client-agent to
# manage -- pass --force to install it anyway, e.g. for a deliberate
# dual-path egress policy. Same mechanism Terraform's client-fleet
# module wires up automatically for "vlan_only"/"vpc_vlan" client_groups
# (ansible/cloud-init/client-node.yaml.tftpl), packaged here as a
# standalone script for a server that already exists outside Terraform.
#
# Split into two scripts, 2026-09-10, from what was previously a single
# combined install-nat-client.sh that also applied the VLAN address
# itself -- VLAN addressing and NAT routing are genuinely separate
# concerns. Run configure-vlan-address.sh FIRST; this script assumes
# --vlan-iface already has a real address on it and fails fast,
# pointing you at that script, if it doesn't.
#
# Does NOT touch the VLAN interface's address at all -- not applying it,
# not verifying it's collision-free, not persisting it across a reboot.
# See configure-vlan-address.sh for all of that.
#
# Also sets net.ipv4.fib_multipath_hash_policy=1 (5-tuple ECMP hashing)
# unconditionally -- the kernel default (0) hashes only source+
# destination IP, so repeated connections to one fixed destination
# deterministically land on the same NAT node every time regardless of
# how many nodes are healthy. Plain kernel sysctl, same fix on any
# distro. See roadmap/M21-ecmp-hash-policy-gap.md.
#
# -----------------------------------------------------
# Two ways to run this:
#
# 1) MANUALLY, on an already-running server, as root, with flags, AFTER
#    configure-vlan-address.sh has already applied a real address to
#    the VLAN interface. No internet access needed on this server --
#    client-agent is fetched over the roster connection itself (see
#    --artifact-base-url below):
#
#    ./install-nat-client.sh \
#      --roster-url http://10.60.32.20:8099/fleet/shared \
#      --vlan-iface eth1
#
# 2) As LINODE USER DATA (Cloud Manager "Add-ons" tab at create time, or
#    `linode-cli linodes rebuild --metadata.user_data`), so a fresh
#    instance configures itself at first boot with no manual step at
#    all -- paste configure-vlan-address.sh's body first, then this
#    script's, both with their flags set as exported environment
#    variables instead (user-data scripts run with no arguments):
#
#    #!/usr/bin/env bash
#    export LNG_VLAN_IP="192.168.100.251/22"
#    # ... configure-vlan-address.sh's body from "set -euo pipefail" ...
#    export LNG_ROSTER_URL="http://10.60.32.20:8099/fleet/shared"
#    export LNG_VLAN_IFACE="eth1"
#    # ... this script's own body from "set -euo pipefail" down ...
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
# 2) --vlan-iface <name> / LNG_VLAN_IFACE (required)
#      Which network interface is the VLAN one -- must already have a
#      real address on it (run configure-vlan-address.sh first if not;
#      this script checks and fails fast with that exact guidance
#      otherwise). Required, not auto-detected: unlike
#      configure-vlan-address.sh, there's no "addressless interface"
#      heuristic that makes sense here, since by the time this script
#      runs the VLAN interface should already have an address -- an
#      addressless one would be a sign something upstream went wrong,
#      not a hint about which interface to use.
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
# 4) --fallback-probe-enabled true|false / LNG_FALLBACK_PROBE_ENABLED
#      (optional, default false) -- roadmap/M24-scalable-roster-health-distribution.md:
#      this client trusts natctl's own computed node health by default
#      (zero direct probing of NAT nodes). Set true for the extra
#      insurance of also independently probing each node directly,
#      ANDed with natctl's own view -- can also be set/overridden
#      fleet-wide, live, via `natctl_cli set-client-config` (see
#      docs/RUNBOOK.md), no restart needed either way.
# 5) --fallback-probe-interval <3-60 seconds> / LNG_FALLBACK_PROBE_INTERVAL
#      (optional, default 30) -- only meaningful when the fallback probe
#      above is enabled.
# 6) --health-probe-timeout <seconds> / LNG_HEALTH_PROBE_TIMEOUT (optional, default 1.5)
#      Match client-agent/lng-client-agent.env.example's own defaults --
#      only override if you've tuned these elsewhere in your fleet.
#
# 7) --force / LNG_FORCE=true (optional flag, no value -- default false)
#      DEFAULT BEHAVIOR: this script checks whether this instance
#      already has a WORKING default route (a real, verified request
#      over it, not just route presence -- found live 2026-09-10: a
#      vpc_vlan instance's VPC interface, if marked primary with no 1:1
#      NAT, still gets a default route from Linode's own Network Helper
#      that structurally cannot reach the internet, and a plain
#      route-presence check was fooled by it) BEFORE touching
#      client-agent. Found one -> client-agent is NOT installed, since
#      there's nothing for it to manage (the "public_vlan"/
#      "public_vpc_vlan" interface_mode shapes, see docs/ARCHITECTURE.md
#      section 3.1). Found none (or a non-functional one) -> client-agent
#      IS installed and takes over the default route
#      ("vlan_only"/"vpc_vlan"). Pass --force to skip this check and
#      install/start client-agent unconditionally -- for a deliberate
#      dual-path egress policy where you want every packet routed
#      through this fleet's static IP pool even though the instance
#      technically has another way out already. Once installed by ANY
#      run of this script (forced or not), a later re-run without
#      --force still reinstalls/restarts it rather than removing it --
#      this flag only affects the decision on a run where client-agent
#      isn't already present.
#
# -----------------------------------------------------
# Best Practices:
#
# - Run configure-vlan-address.sh first. This script fails fast with a
#   clear message pointing you back at it if --vlan-iface has no address.
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
    --vlan-iface) LNG_VLAN_IFACE="$2"; shift 2 ;;
    --artifact-base-url) LNG_ARTIFACT_BASE_URL="$2"; shift 2 ;;
    --fallback-probe-enabled) LNG_FALLBACK_PROBE_ENABLED="$2"; shift 2 ;;
    --fallback-probe-interval) LNG_FALLBACK_PROBE_INTERVAL="$2"; shift 2 ;;
    --health-probe-timeout) LNG_HEALTH_PROBE_TIMEOUT="$2"; shift 2 ;;
    --force) LNG_FORCE=true; shift ;;
    *) echo "Unknown arg: $1" >&2; exit 1 ;;
  esac
done

: "${LNG_ROSTER_URL:?--roster-url (or LNG_ROSTER_URL) is required, e.g. http://10.60.32.20:8099/fleet/shared}"
: "${LNG_VLAN_IFACE:?--vlan-iface (or LNG_VLAN_IFACE) is required, e.g. eth1 -- run configure-vlan-address.sh first if that is not already known}"
# LNG_ARTIFACT_BASE_URL is intentionally optional now -- see the
# --artifact-base-url parameter comment above. Left unset, client-agent
# is fetched from natctl's own roster API instead of an internet-facing
# Object Storage URL, which is what actually works for a private-only
# ("vlan_only"/"vpc_vlan") client (confirmed live, 2026-09-01, against a
# genuinely internet-less test client -- the bucket-URL fetch just hung
# on DNS resolution, exactly as expected for a host with no route out).
LNG_FALLBACK_PROBE_ENABLED="${LNG_FALLBACK_PROBE_ENABLED:-false}"
LNG_FALLBACK_PROBE_INTERVAL="${LNG_FALLBACK_PROBE_INTERVAL:-30}"
LNG_HEALTH_PROBE_TIMEOUT="${LNG_HEALTH_PROBE_TIMEOUT:-1.5}"
LNG_FORCE="${LNG_FORCE:-false}"

if [[ "$(id -u)" -ne 0 ]]; then
  echo "Must run as root." >&2
  exit 1
fi

# This script configures a Linux network stack directly (sysctl under
# /proc/sys/net/ipv4, `ip` nexthop/route commands, systemd) -- it must
# run ON the target client instance itself, not on whatever machine is
# driving your automation. Caught live, 2026-09-08: run on macOS, the
# very first step below (a Linux-only sysctl) fails with a cryptic BSD
# "sysctl: unknown oid" error that reads like a kernel/config problem
# on the *target*, when the real issue is just the wrong host running
# it -- macOS has no net.ipv4.fib_multipath_hash_policy at all. Fail
# fast with an actionable message instead.
if [[ "$(uname -s)" != "Linux" ]]; then
  echo "This script must run on the Linux client instance itself (detected: $(uname -s))." >&2
  echo "SSH into the target Linode and run it there, or deliver it as that instance's own user-data -- see the usage comment at the top of this file." >&2
  exit 1
fi

# Found live 2026-09-10, right after the VLAN-addressing/NAT-routing
# split: this script assumes --vlan-iface already has a real address on
# it (configure-vlan-address.sh's job) -- verify that assumption
# explicitly and fail with clear, actionable guidance rather than
# silently proceeding to build a route through an unaddressed interface,
# which would look like it worked but never actually pass traffic.
if ! ip -4 -o addr show dev "${LNG_VLAN_IFACE}" 2>/dev/null | grep -q inet; then
  echo "ERROR: ${LNG_VLAN_IFACE} has no IPv4 address configured." >&2
  echo "Run configure-vlan-address.sh first (e.g. './configure-vlan-address.sh --vlan-ip 192.168.100.251/22 --vlan-iface ${LNG_VLAN_IFACE}'), then re-run this script." >&2
  exit 1
fi

# Captured before anything below changes it -- purely for the "Summary of
# changes" block at the very end (operators reasonably want a real
# before/after record of what this script actually did, not just a
# one-line "Done."), never read/branched on anywhere else.
LNG_ORIGINAL_DEFAULT_ROUTE="$(ip route show default 2>/dev/null || true)"

# 0. Set the ECMP multipath hash policy. This is a plain kernel sysctl,
#    identical across every Linux distro this script supports --
#    unrelated to VLAN addressing, so it's applied unconditionally,
#    before anything else. The kernel default (0) hashes only
#    source+destination IP, so many separate connections to the SAME
#    destination (e.g. repeated `curl http://ifconfig.me`)
#    deterministically hash to the SAME nexthop every time -- this is
#    what actually makes client-agent's resilient-nexthop-group routing
#    deliver its claimed "consistent per-flow hashing, spread across
#    every healthy node" property, rather than a route/health problem.
#    Confirmed live, 2026-09-01/09-02, on multiple test clients -- see
#    roadmap/M21-ecmp-hash-policy-gap.md.
sysctl -w net.ipv4.fib_multipath_hash_policy=1 >/dev/null
mkdir -p /etc/sysctl.d
cat >/etc/sysctl.d/99-lng-ecmp.conf <<'EOF'
net.ipv4.fib_multipath_hash_policy=1
EOF
echo "Set net.ipv4.fib_multipath_hash_policy=1 (5-tuple ECMP hashing), persisted in /etc/sysctl.d/99-lng-ecmp.conf."

# 1. Decide whether client-agent belongs on this instance at all -- see
#    the --force parameter comment above for the full reasoning. Order
#    matters: an already-installed unit (a prior run of this script,
#    forced or not) always wins, so a re-run never flip-flops based on
#    whatever the route table happens to look like at that moment --
#    only the FIRST run's decision (or an explicit --force) matters.
if [[ "${LNG_FORCE}" == "true" ]]; then
  LNG_INSTALL_CLIENT_AGENT=true
  echo "--force given -- installing client-agent regardless of any existing default route."
elif [[ -f /etc/systemd/system/lng-client-agent.service ]]; then
  LNG_INSTALL_CLIENT_AGENT=true
  echo "client-agent is already installed from a previous run of this script -- re-run will update it in place."
elif ip route show default 2>/dev/null | grep -q . && timeout 3 python3 -c "
import urllib.request, sys
try:
    urllib.request.urlopen('https://api.linode.com/v4/regions', timeout=3)
except Exception:
    sys.exit(1)
" >/dev/null 2>&1; then
  LNG_INSTALL_CLIENT_AGENT=false
  echo "This instance already has a WORKING default route via another interface (verified real reachability, not just route presence) -- client-agent will NOT be installed (nothing for it to manage)."
  echo "Pass --force to install and start it anyway, e.g. for a deliberate dual-path egress policy."
else
  LNG_INSTALL_CLIENT_AGENT=true
  # Found live 2026-09-10: a plain `ip route show default` presence check
  # (this line's old behavior) is fooled by a vpc_vlan instance -- a VPC
  # interface marked primary, with no 1:1 NAT, still gets a default route
  # from Linode's own boot-time Network Helper on the ifupdown stack, even
  # though a VPC interface with no 1:1 NAT structurally cannot reach the
  # internet at all (see docs/ARCHITECTURE.md §3.0) -- that route exists
  # but doesn't work. Confirmed live: install-nat-client.sh skipped
  # installing client-agent on exactly this shape, leaving the instance
  # with no real egress path at all. Now actually attempts a real request
  # over whatever default route exists (api.linode.com, 3s timeout) before
  # trusting it -- a route that's present but non-functional is treated
  # the same as no route at all.
  if ip route show default 2>/dev/null | grep -q .; then
    echo "A default route exists but doesn't actually reach the internet (e.g. a VPC interface with no 1:1 NAT) -- installing client-agent to provide a working one via the NAT fleet."
  else
    echo "No existing default route found -- installing client-agent to provide one via the NAT fleet."
  fi
fi

if [[ "${LNG_INSTALL_CLIENT_AGENT}" == "true" ]]; then

# 2. Fetch the compiled client-agent binary. python3, not curl -- every
#    Ubuntu cloud image guarantees python3 (cloud-init itself needs it),
#    but curl needs an apt-get install, which needs internet access this
#    host may not have yet if its only path out is the NAT gateway this
#    script hasn't finished configuring (same chicken-and-egg reasoning
#    as ansible/cloud-init/client-node.yaml.tftpl).
#
#    Stop the service first if this is a re-run -- overwriting a binary
#    that's currently executing fails with "Text file busy" (ETXTBSY),
#    confirmed live, 2026-09-02, breaking this script's own "safe to
#    re-run" claim otherwise. No-op (and harmless) on a first run, where
#    the service/unit doesn't exist yet.
systemctl stop lng-client-agent 2>/dev/null || true
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

# 3. Config.
mkdir -p /etc/lng-client-agent
cat >/etc/lng-client-agent/env <<EOF
NATCTL_ROSTER_URL=${LNG_ROSTER_URL}
LNG_PRIVATE_IFACE=${LNG_VLAN_IFACE}
LNG_HEALTH_PROBE_TIMEOUT=${LNG_HEALTH_PROBE_TIMEOUT}
LNG_DRY_RUN=false
LNG_FALLBACK_PROBE_ENABLED=${LNG_FALLBACK_PROBE_ENABLED}
LNG_FALLBACK_PROBE_INTERVAL=${LNG_FALLBACK_PROBE_INTERVAL}
EOF

# 4. systemd unit -- static, non-secret content, embedded directly
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

fi  # LNG_INSTALL_CLIENT_AGENT

# Found live 2026-09-10: a real, itemized record of what this run
# actually did -- not just "Done." -- so an operator can see exactly
# what changed without having to already know this script's internals.
echo ""
echo "===== Summary of changes ====="
echo "ECMP hash policy: net.ipv4.fib_multipath_hash_policy=1 (file: /etc/sysctl.d/99-lng-ecmp.conf)"
echo "Default route:"
echo "  before: ${LNG_ORIGINAL_DEFAULT_ROUTE:-<none>}"
echo "  after:  $(ip route show default 2>/dev/null || echo '<none>')"
if [[ "${LNG_INSTALL_CLIENT_AGENT}" == "true" ]]; then
  echo "client-agent:     installed and started (systemd unit: lng-client-agent.service)"
  echo "  binary:         /opt/lng-client-agent/client-agent"
  echo "  env file:       /etc/lng-client-agent/env"
  echo "  unit file:      /etc/systemd/system/lng-client-agent.service"
  echo "  This service now continuously long-polls the roster and keeps the"
  echo "  default route's ECMP nexthop group in sync with which nodes are"
  echo "  healthy -- it is the thing that changed the default route above,"
  echo "  and keeps changing it live as the fleet's health changes."
else
  echo "client-agent:     NOT installed -- this instance already has a working default route of its own (pass --force to install it anyway)."
fi
echo "==============================="
echo ""
echo "Verify with:"
echo "  ip route"
if [[ "${LNG_INSTALL_CLIENT_AGENT}" == "true" ]]; then
  echo "  journalctl -u lng-client-agent -f"
fi
echo "  curl -s https://ifconfig.me"

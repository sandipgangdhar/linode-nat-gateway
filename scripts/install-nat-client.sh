#!/usr/bin/env bash
# install-nat-client.sh (scripts)
#
# Sets up NAT routing on an existing Linode that already has a static
# VLAN address applied. If this instance doesn't already have a working
# default route of its own, fetches the compiled client-agent binary
# from your artifacts bucket and installs it as a systemd service that
# manages ECMP routing across every healthy node in the pool. An
# instance that already has its own working path out (a public IP, or a
# VPC interface with 1:1 NAT) is left alone by default, since there'd be
# nothing for client-agent to manage -- pass --force to install it
# anyway, e.g. for a deliberate dual-path egress policy.
#
# Does NOT touch the VLAN interface's address at all -- applying a
# working static VLAN address (this project's own nodes' reserved
# sub-block, see docs/NAT-GATEWAY-DEFINITIVE-GUIDE.html §3.4, is
# off-limits; anywhere else on the pool's wide VLAN CIDR is fine) is
# entirely your own automation's responsibility, not something this
# project provides tooling for -- this script only ever verifies that
# --vlan-iface already has a real address applied, as a safety check
# against building a route through an unaddressed interface, never
# applies one itself.
#
# Also sets net.ipv4.fib_multipath_hash_policy=1 (5-tuple ECMP hashing)
# unconditionally -- the kernel default (0) hashes only source+
# destination IP, so repeated connections to one fixed destination
# deterministically land on the same NAT node every time regardless of
# how many nodes are healthy. Plain kernel sysctl, same fix on any
# distro.
#
# -----------------------------------------------------
# Two ways to run this:
#
# 1) MANUALLY, on an already-running server, as root, with flags, AFTER
#    your own automation has already applied a real static address to
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
#    all -- apply the VLAN address yourself first (whatever your own
#    automation already does for that), then run this script's body
#    with its flags set as exported environment variables instead
#    (user-data scripts run with no arguments):
#
#    #!/usr/bin/env bash
#    # ... your own automation's VLAN-addressing step goes here ...
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
#      docs/NAT-GATEWAY-DEFINITIVE-GUIDE.html §3.3's callout on
#      cross-subnet VPC reachability).
#
# 2) --vlan-iface <name> / LNG_VLAN_IFACE (required)
#      Which network interface is the VLAN one -- must already have a
#      real address on it (apply one with your own automation first if
#      not; this script checks and fails fast with actionable guidance
#      otherwise). Required, not auto-detected: by the time this script
#      runs the VLAN interface should already have an address -- an
#      addressless one is a sign something upstream went wrong, not a
#      hint about which interface to use.
#
# 3) --artifact-base-url <url> / LNG_ARTIFACT_BASE_URL (optional)
#      DEFAULT BEHAVIOR (no flag needed): client-agent is fetched from
#      natctl's own roster API -- GET <roster origin>/agents/client-agent
#      -- derived automatically from --roster-url by stripping its path.
#      This is deliberate, not a shortcut: a "vlan_only"/"vpc_vlan" client
#      has NO internet path of its own until client-agent itself brings
#      one up (that's the entire point of those modes), so it can never
#      reach an internet-facing Object Storage URL directly -- the fetch
#      just hangs on DNS resolution against a genuinely private-only
#      client, exactly as expected for a host with no route out. natctl itself
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
#      (optional, default false) -- this client trusts natctl's own
#      computed node health by default (zero direct probing of NAT
#      nodes). Set true for the extra insurance of also independently
#      probing each node directly, ANDed with natctl's own view -- can
#      also be set/overridden fleet-wide, live, via
#      `natctl_cli set-client-config` (see
#      docs/NAT-GATEWAY-DEFINITIVE-GUIDE.html §10.2), no restart needed
#      either way.
# 5) --fallback-probe-interval <3-60 seconds> / LNG_FALLBACK_PROBE_INTERVAL
#      (optional, default 30) -- only meaningful when the fallback probe
#      above is enabled.
# 6) --health-probe-timeout <seconds> / LNG_HEALTH_PROBE_TIMEOUT (optional, default 1.5)
#      Match client-agent/lng-client-agent.env.example's own defaults --
#      only override if you've tuned these elsewhere in your fleet.
#
# 7) --vpc-iface <name> / LNG_VPC_IFACE (optional)
#      Only relevant for a "vlan_only"/"vpc_vlan" instance -- i.e. one
#      whose VPC interface WAS its own default interface before this
#      script ran. That default route (even though it can't reach the
#      internet, see --force above) may have been giving this instance
#      real reachability to OTHER subnets in the same VPC, since Akamai's
#      VPC fabric forwards a packet between two sibling subnets of the
#      same VPC when explicitly routed via the VPC interface -- no
#      gateway IP needed, an on-link route is enough (mirrors exactly
#      how terraform/modules/vpc's own vpc_sibling_subnet_cidrs mechanism
#      routes NAT nodes to every other VPC subnet). Once client-agent
#      (below) takes over the default route for internet egress via the
#      NAT fleet, that implicit sibling-subnet reachability is gone --
#      the default route now points at the VLAN, not VPC. DO NOT point
#      the default route itself at the fleet's VPC addresses to "fix"
#      this -- NAT nodes' VPC interface is deliberately scoped to
#      buddy-pair conntrackd sync only (see docs/ARCHITECTURE.md §3.0);
#      it never masquerades client traffic out to the internet, so
#      internet egress would break outright.
#
#      This flag just tells client-agent which interface is VPC
#      (LNG_VPC_IFACE in its own env file) -- client-agent itself then
#      adds/removes explicit, non-default routes to whatever VPC subnets
#      natctl's roster currently reports (Terraform-auto-discovered,
#      same source `vpc_sibling_subnet_cidrs` already uses on the
#      NAT-node side), self-healing on every roster update. A subnet the
#      customer adds to the VPC later reaches every connected client
#      automatically, with no re-run of this script needed on any of
#      them -- see docs/ARCHITECTURE.md §8.7 and
#      client-agent/lng-client-agent.env.example's own LNG_VPC_IFACE
#      comment for the full mechanism.
#      Example: --vpc-iface eth0
#
# 8) --force / LNG_FORCE=true (optional flag, no value -- default false)
#      DEFAULT BEHAVIOR: this script checks whether this instance
#      already has a WORKING default route (a real, verified request
#      over it, not just route presence -- a vpc_vlan instance's VPC
#      interface, if marked primary with no 1:1 NAT, still gets a
#      default route from Linode's own Network Helper that structurally
#      cannot reach the internet, and a plain route-presence check is
#      fooled by it) BEFORE touching
#      client-agent. Found one -> client-agent is NOT installed, since
#      there's nothing for it to manage (the "public_vlan"/
#      "public_vpc_vlan" interface_mode shapes, see
#      docs/NAT-GATEWAY-DEFINITIVE-GUIDE.html §3.3's interface table).
#      Found none (or a non-functional one) -> client-agent
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
# - Apply a real static address to --vlan-iface with your own automation
#   first. This script fails fast with a clear message if it doesn't
#   find one -- it never applies an address itself.
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

# Kept in sync with the "Parameters" section of this file's own header
# comment above -- that's the authoritative full explanation of every
# flag's "why"; this is the quick-reference version.
print_help() {
  cat <<'EOF'
Usage: install-nat-client.sh --roster-url <url> --vlan-iface <name> [options]

Sets up NAT routing on an existing Linode that already has a static VLAN
address applied. Fetches and installs client-agent (unless this instance
already has its own working default route) to manage ECMP routing across
every healthy node in the target pool.

Required:
  --roster-url <url>              natctl's roster URL for this client's
                                   pool, e.g.
                                   http://10.60.32.20:8099/fleet/shared
                                   (comma-separated list accepted for
                                   failover across natctl-on-node peers)
  --vlan-iface <name>              This instance's VLAN interface -- must
                                   already have a real static address
                                   applied by your own automation first

Optional:
  --artifact-base-url <url>       Fetch client-agent from this Object
                                   Storage base URL instead of natctl's
                                   roster API (default: derived from
                                   --roster-url; only needed for a client
                                   that already has its own internet path)
  --fallback-probe-enabled true|false
                                   Also independently probe each node
                                   directly, ANDed with natctl's own
                                   reported health (default: false)
  --fallback-probe-interval <3-60>
                                   Fallback probe interval in seconds,
                                   only meaningful if enabled (default: 30)
  --health-probe-timeout <seconds>
                                   Per-probe HTTP timeout (default: 1.5)
  --vpc-iface <name>               This instance's VPC interface, if it
                                   has one -- lets client-agent restore
                                   reachability to other VPC subnets its
                                   own default route would otherwise
                                   remove, self-healing from natctl's
                                   roster (default: unset, no effect --
                                   see docs/ARCHITECTURE.md §8.7)
  --force                          Install/start client-agent even if
                                   this instance already has a working
                                   default route of its own (default:
                                   false -- skip if one's already found)
  --help, -h                       Show this help and exit

Examples:
  ./install-nat-client.sh --roster-url http://10.60.32.20:8099/fleet/shared \
    --vlan-iface eth1

  ./install-nat-client.sh --roster-url http://10.60.32.20:8099/fleet/shared \
    --vlan-iface eth1 --vpc-iface eth0

Every flag also has an equivalent LNG_* environment variable (for use as
Linode user-data, where scripts run with no arguments) -- see this file's
own header comment for the full mapping and the "why" behind each one, or
docs/RUNBOOK.md's "Onboard a client instance" / docs/ARCHITECTURE.md §8.7.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --help|-h) print_help; exit 0 ;;
    --roster-url) LNG_ROSTER_URL="$2"; shift 2 ;;
    --vlan-iface) LNG_VLAN_IFACE="$2"; shift 2 ;;
    --artifact-base-url) LNG_ARTIFACT_BASE_URL="$2"; shift 2 ;;
    --fallback-probe-enabled) LNG_FALLBACK_PROBE_ENABLED="$2"; shift 2 ;;
    --fallback-probe-interval) LNG_FALLBACK_PROBE_INTERVAL="$2"; shift 2 ;;
    --health-probe-timeout) LNG_HEALTH_PROBE_TIMEOUT="$2"; shift 2 ;;
    --vpc-iface) LNG_VPC_IFACE="$2"; shift 2 ;;
    --force) LNG_FORCE=true; shift ;;
    *) echo "Unknown arg: $1 (see --help)" >&2; exit 1 ;;
  esac
done

: "${LNG_ROSTER_URL:?--roster-url (or LNG_ROSTER_URL) is required, e.g. http://10.60.32.20:8099/fleet/shared}"
: "${LNG_VLAN_IFACE:?--vlan-iface (or LNG_VLAN_IFACE) is required, e.g. eth1 -- apply a real static VLAN address to it with your own automation first if that is not already known}"
# LNG_ARTIFACT_BASE_URL is intentionally optional now -- see the
# --artifact-base-url parameter comment above. Left unset, client-agent
# is fetched from natctl's own roster API instead of an internet-facing
# Object Storage URL, which is what actually works for a private-only
# ("vlan_only"/"vpc_vlan") client -- against a genuinely internet-less
# client, a direct bucket-URL fetch just hangs on DNS resolution,
# exactly as expected for a host with no route out.
LNG_FALLBACK_PROBE_ENABLED="${LNG_FALLBACK_PROBE_ENABLED:-false}"
LNG_FALLBACK_PROBE_INTERVAL="${LNG_FALLBACK_PROBE_INTERVAL:-30}"
LNG_HEALTH_PROBE_TIMEOUT="${LNG_HEALTH_PROBE_TIMEOUT:-1.5}"
LNG_FORCE="${LNG_FORCE:-false}"
LNG_VPC_IFACE="${LNG_VPC_IFACE:-}"

if [[ "$(id -u)" -ne 0 ]]; then
  echo "Must run as root." >&2
  exit 1
fi

# This script configures a Linux network stack directly (sysctl under
# /proc/sys/net/ipv4, `ip` nexthop/route commands, systemd) -- it must
# run ON the target client instance itself, not on whatever machine is
# driving your automation. Run on macOS, the very first step below (a
# Linux-only sysctl) fails with a cryptic BSD "sysctl: unknown oid"
# error that reads like a kernel/config problem on the *target*, when
# the real issue is just the wrong host running it -- macOS has no
# net.ipv4.fib_multipath_hash_policy at all. Fail fast with an
# actionable message instead.
if [[ "$(uname -s)" != "Linux" ]]; then
  echo "This script must run on the Linux client instance itself (detected: $(uname -s))." >&2
  echo "SSH into the target Linode and run it there, or deliver it as that instance's own user-data -- see the usage comment at the top of this file." >&2
  exit 1
fi

# This script assumes --vlan-iface already has a real address applied by
# your own automation -- verify that assumption explicitly and fail with
# clear, actionable guidance rather than silently proceeding to build a
# route through an unaddressed interface, which would look like it
# worked but never actually pass traffic.
if ! ip -4 -o addr show dev "${LNG_VLAN_IFACE}" 2>/dev/null | grep -q inet; then
  echo "ERROR: ${LNG_VLAN_IFACE} has no IPv4 address configured." >&2
  echo "Apply a real static VLAN address to ${LNG_VLAN_IFACE} first (your own automation, or e.g. 'ip addr add 192.168.100.251/22 dev ${LNG_VLAN_IFACE}' -- pick an address outside this pool's reserved sub-block, using the pool's WIDE VLAN CIDR prefix, see docs/NAT-GATEWAY-DEFINITIVE-GUIDE.html §3.4), then re-run this script." >&2
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
sysctl -w net.ipv4.fib_multipath_hash_policy=1 >/dev/null
mkdir -p /etc/sysctl.d
cat >/etc/sysctl.d/99-lng-ecmp.conf <<'EOF'
net.ipv4.fib_multipath_hash_policy=1
EOF
echo "Set net.ipv4.fib_multipath_hash_policy=1 (5-tuple ECMP hashing), persisted in /etc/sysctl.d/99-lng-ecmp.conf."

# 0b. Optional: sanity-check --vpc-iface, if given, has a real address --
#     see this flag's own comment at the top of this file for the full
#     "why". The actual route management (restoring reachability to
#     other VPC subnets, self-healing as the VPC's subnet list changes)
#     is client-agent's own job now (LNG_VPC_IFACE in its env file,
#     step 3 below) -- see docs/ARCHITECTURE.md §8.7 -- this is just an
#     early, actionable failure instead of a silent no-op if the
#     interface named doesn't actually have an address on it.
if [[ -n "${LNG_VPC_IFACE}" ]] && ! ip -4 -o addr show dev "${LNG_VPC_IFACE}" 2>/dev/null | grep -q inet; then
  echo "ERROR: ${LNG_VPC_IFACE} (--vpc-iface) has no IPv4 address configured." >&2
  exit 1
fi

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
  # A plain `ip route show default` presence check is fooled by a
  # vpc_vlan instance -- a VPC interface marked primary, with no 1:1
  # NAT, still gets a default route from Linode's own boot-time Network
  # Helper on the ifupdown stack, even though a VPC interface with no
  # 1:1 NAT structurally cannot reach the internet at all (see
  # docs/NAT-GATEWAY-DEFINITIVE-GUIDE.html §1.2) -- that route exists
  # but doesn't work, and skipping client-agent on exactly this shape
  # would leave the instance with no real egress path at all. Instead,
  # actually attempt a real request over whatever default route exists
  # (api.linode.com, 3s timeout) before trusting it -- a route that's
  # present but non-functional is treated the same as no route at all.
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
#    which would otherwise break this script's own "safe to re-run"
#    claim. No-op (and harmless) on a first run, where the service/unit
#    doesn't exist yet.
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
LNG_VPC_IFACE=${LNG_VPC_IFACE}
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

# `systemctl enable --now` returns as soon as the unit is started, not
# once client-agent has actually fetched the roster and applied its own
# ECMP route -- without this poll, the "Summary of changes" below could
# show no route change even though a real one lands a couple of seconds
# later. client-agent's own initial fetch is a plain (non-long-poll)
# GET, so this is normally quick; poll briefly for the route to
# actually change before capturing "after", rather than reporting a
# stale snapshot as if it were final.
for _ in $(seq 1 20); do
  CURRENT_DEFAULT_ROUTE="$(ip route show default 2>/dev/null || true)"
  [[ "${CURRENT_DEFAULT_ROUTE}" != "${LNG_ORIGINAL_DEFAULT_ROUTE:-}" ]] && break
  sleep 0.5
done

fi  # LNG_INSTALL_CLIENT_AGENT

# A real, itemized record of what this run actually did -- not just
# "Done." -- so an operator can see exactly what changed without having
# to already know this script's internals.
echo ""
echo "===== Summary of changes ====="
echo "ECMP hash policy: net.ipv4.fib_multipath_hash_policy=1 (file: /etc/sysctl.d/99-lng-ecmp.conf)"
if [[ -n "${LNG_VPC_IFACE}" ]]; then
  echo "VPC sibling routes: client-agent will self-manage these via ${LNG_VPC_IFACE}, from natctl's own roster (see 'ip route' after it's up, and docs/ARCHITECTURE.md §8.7)"
fi
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

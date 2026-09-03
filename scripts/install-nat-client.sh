#!/usr/bin/env bash
# install-nat-client.sh (scripts)
#
# Turns any existing Linode into a client of this NAT gateway fleet:
# sets a persistent static address on its VLAN interface, and -- if this
# instance doesn't already have a default route of its own -- fetches the
# compiled client-agent binary from your artifacts bucket and installs it
# as a systemd service that manages ECMP routing across every healthy
# node in the pool. An instance that already has its own path out (a
# public IP, or a VPC interface with 1:1 NAT) is left alone by default,
# since there'd be nothing for client-agent to manage -- pass --force to
# install it anyway, e.g. for a deliberate dual-path egress policy. Same
# mechanism Terraform's client-fleet module wires up automatically for
# "vlan_only"/"vpc_vlan" client_groups (ansible/cloud-init/
# client-node.yaml.tftpl), packaged here as a standalone script for a
# server that already exists outside Terraform.
#
# Does NOT attach the VLAN interface itself -- that's a Linode
# account-level action (Cloud Manager, or `linode-cli linodes
# interface-add --vlan.vlan_label <label> --vlan.ipam_address <cidr>`,
# power the instance off first if replacing an existing interface). This
# script only configures what's already attached.
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
#      IMPORTANT: on the "ifupdown" network stack (see --linode-api-token
#      below) this heuristic often FAILS, because Linode's own Network
#      Helper pre-assigns the config profile's IPAM address to the VLAN
#      interface before this script ever runs -- confirmed live,
#      2026-09-02, on a Debian 12 test client. Pass this flag explicitly
#      on that stack.
#
# 4a) --linode-api-token <token> / LNG_LINODE_API_TOKEN (optional, but
#      required for a DURABLE fix on the "ifupdown" network stack)
#      This script detects which stack manages this image's network
#      config: "systemd-networkd" (a plain drop-in .network file is
#      enough, e.g. newer "linode"-interface-generation Ubuntu images
#      with no Network Helper) or "ifupdown" (classic config-profile
#      images -- confirmed live on Debian 12, likely also older/legacy
#      Ubuntu config profiles). On "ifupdown", Linode's own Network
#      Helper fully REGENERATES /etc/network/interfaces (and
#      /etc/resolv.conf) from the Linode config profile on EVERY boot --
#      any local file this script writes there would just be silently
#      discarded on next reboot. The only durable fix on that stack is
#      updating the config profile's own VLAN interface ipam_address via
#      the Linode API -- the same mechanism Terraform already uses for
#      floor nodes -- which is what this token is for. Without it, the
#      address is still applied for the CURRENT boot (so you can test
#      immediately) but reverts on the next reboot; the script prints an
#      explicit warning and the manual fix command in that case. This
#      step deliberately runs LAST (after client-agent/ECMP is up), not
#      up front -- a "vlan_only"/"vpc_vlan" client has no internet path
#      of its own until client-agent brings one up, so calling
#      api.linode.com any earlier would hit the exact same chicken-and-
#      egg failure the client-agent fetch (below) already works around.
#      Only needs read/write access to Linode Instances -- scope it
#      narrowly. Never pass this on the command line on a shared/logged
#      shell -- prefer the LNG_LINODE_API_TOKEN env var, and see this
#      repo's own credential-handling convention (CLAUDE.md) either way.
#
# 5) --dns-servers "<ip1>,<ip2>,..." / LNG_DNS_SERVERS (optional, comma-
#      or space-separated)
#      A "vlan_only"/"vpc_vlan" client has no public interface, so it
#      never gets the DNS resolvers Linode's own cloud-init/DHCP normally
#      writes for eth0 -- left unconfigured, IP-based egress through the
#      NAT fleet still works, but every hostname-based connection (curl
#      to a domain, apt, etc.) fails. AUTO-DETECTED BY DEFAULT on the
#      "systemd-networkd" stack if this flag is omitted -- no need to
#      look resolver IPs up by hand: this script first reuses whatever's
#      already in /etc/resolv.conf (e.g. from a working VPC-DHCP-provided
#      resolver on another interface), and if nothing usable is found
#      there, asks Linode's own regions API directly (self-identifying
#      this instance's region via the Metadata Service, same mechanism
#      as --linode-api-token above -- no auth needed for the regions
#      lookup itself; see
#      https://techdocs.akamai.com/cloud-computing/docs/dns-resolvers).
#      That second step needs real internet access, so it can still fail
#      on a genuinely internet-less client at this point in the script --
#      caught with a bounded timeout, falling back to "leave DNS
#      unconfigured" with an explicit warning, same as before. Pass this
#      flag explicitly to override auto-detection (e.g. you know your
#      resolvers already, or auto-detection picked something wrong).
#      IGNORED on the "ifupdown" network stack (see --linode-api-token
#      above) either way -- Network Helper already generates a correct
#      /etc/resolv.conf there on every boot, confirmed live on the same
#      Debian 12 test client, so neither this flag nor auto-detection
#      applies there.
#
# 6) --dns-search-domain <domain> / LNG_DNS_SEARCH_DOMAIN
#      (optional, default "members.linode.com")
# 7) --dns-default-route true|false / LNG_DNS_DEFAULT_ROUTE
#      (optional, default "true" -- this interface is usually the only
#      one with any DNS config on a private-only client, so it should
#      also be the one systemd-resolved routes lookups through)
#
# 8) --fallback-probe-enabled true|false / LNG_FALLBACK_PROBE_ENABLED
#      (optional, default false) -- roadmap/M24-scalable-roster-health-distribution.md:
#      this client trusts natctl's own computed node health by default
#      (zero direct probing of NAT nodes). Set true for the extra
#      insurance of also independently probing each node directly,
#      ANDed with natctl's own view -- can also be set/overridden
#      fleet-wide, live, via `natctl_cli set-client-config` (see
#      docs/RUNBOOK.md), no restart needed either way.
# 9) --fallback-probe-interval <3-60 seconds> / LNG_FALLBACK_PROBE_INTERVAL
#      (optional, default 30) -- only meaningful when the fallback probe
#      above is enabled.
# 10) --health-probe-timeout <seconds> / LNG_HEALTH_PROBE_TIMEOUT (optional, default 1.5)
#      Match client-agent/lng-client-agent.env.example's own defaults --
#      only override if you've tuned these elsewhere in your fleet.
#
# 11) --force / LNG_FORCE=true (optional flag, no value -- default false)
#      DEFAULT BEHAVIOR: this script checks for an existing default route
#      BEFORE touching client-agent. Found one (this instance already has
#      its own path out -- a public IP via Network Helper/DHCP, or a VPC
#      interface with 1:1 NAT) -> client-agent is NOT installed, since
#      there's nothing for it to manage (the "public_vlan"/
#      "public_vpc_vlan" interface_mode shapes, see docs/ARCHITECTURE.md
#      section 3.1). Found none -> client-agent IS installed and takes
#      over the default route ("vlan_only"/"vpc_vlan"). Pass --force to
#      skip this check and install/start client-agent unconditionally --
#      for a deliberate dual-path egress policy where you want every
#      packet routed through this fleet's static IP pool even though the
#      instance technically has another way out already. Once installed
#      by ANY run of this script (forced or not), a later re-run without
#      --force still reinstalls/restarts it rather than removing it --
#      this flag only affects the decision on a run where client-agent
#      isn't already present.
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
    --dns-servers) LNG_DNS_SERVERS="$2"; shift 2 ;;
    --dns-search-domain) LNG_DNS_SEARCH_DOMAIN="$2"; shift 2 ;;
    --dns-default-route) LNG_DNS_DEFAULT_ROUTE="$2"; shift 2 ;;
    --linode-api-token) LNG_LINODE_API_TOKEN="$2"; shift 2 ;;
    --fallback-probe-enabled) LNG_FALLBACK_PROBE_ENABLED="$2"; shift 2 ;;
    --fallback-probe-interval) LNG_FALLBACK_PROBE_INTERVAL="$2"; shift 2 ;;
    --health-probe-timeout) LNG_HEALTH_PROBE_TIMEOUT="$2"; shift 2 ;;
    --force) LNG_FORCE=true; shift ;;
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
LNG_DNS_SEARCH_DOMAIN="${LNG_DNS_SEARCH_DOMAIN:-members.linode.com}"
LNG_DNS_DEFAULT_ROUTE="${LNG_DNS_DEFAULT_ROUTE:-true}"
LNG_FALLBACK_PROBE_ENABLED="${LNG_FALLBACK_PROBE_ENABLED:-false}"
LNG_FALLBACK_PROBE_INTERVAL="${LNG_FALLBACK_PROBE_INTERVAL:-30}"
LNG_HEALTH_PROBE_TIMEOUT="${LNG_HEALTH_PROBE_TIMEOUT:-1.5}"
LNG_FORCE="${LNG_FORCE:-false}"

if [[ "$(id -u)" -ne 0 ]]; then
  echo "Must run as root." >&2
  exit 1
fi

# 0. Set the ECMP multipath hash policy. This is a plain kernel sysctl,
#    identical across every Linux distro/interface-generation this
#    script supports (Ubuntu, Debian, systemd-networkd or ifupdown
#    alike) -- unrelated to the network-stack branching below, so it's
#    applied unconditionally, before anything else. The kernel default
#    (0) hashes only source+destination IP, so many separate
#    connections to the SAME destination (e.g. repeated
#    `curl http://ifconfig.me`) deterministically hash to the SAME
#    nexthop every time -- this is what actually makes client-agent's
#    resilient-nexthop-group routing deliver its claimed "consistent
#    per-flow hashing, spread across every healthy node" property,
#    rather than a route/health problem. Confirmed live, 2026-09-01/
#    09-02, on multiple test clients -- see
#    roadmap/M21-ecmp-hash-policy-gap.md.
sysctl -w net.ipv4.fib_multipath_hash_policy=1 >/dev/null
mkdir -p /etc/sysctl.d
cat >/etc/sysctl.d/99-lng-ecmp.conf <<'EOF'
net.ipv4.fib_multipath_hash_policy=1
EOF
echo "Set net.ipv4.fib_multipath_hash_policy=1 (5-tuple ECMP hashing), persisted in /etc/sysctl.d/99-lng-ecmp.conf."

# 1. Detect which network stack manages this image's interfaces --
#    systemd-networkd (newer "linode"-interface-generation images with
#    no Network Helper running) accepts a plain drop-in .network file;
#    classic config-profile images instead use ifupdown, with Linode's
#    own "Network Helper" fully REGENERATING /etc/network/interfaces
#    (and /etc/resolv.conf) from the Linode config profile on every
#    single boot -- confirmed live, 2026-09-02, on a Debian 12 test
#    client. A local file is a no-op on that stack; see step 8.
if systemctl is-active --quiet systemd-networkd 2>/dev/null; then
  LNG_NET_STACK="networkd"
else
  LNG_NET_STACK="ifupdown"
fi
echo "Detected network stack: ${LNG_NET_STACK}"

# 2. Identify the VLAN interface if not given explicitly -- the first
#    non-loopback interface with no IPv4 address, since Linode never
#    auto-assigns one to a VLAN interface on the "networkd" stack
#    (unlike VPC, which gets DHCP). On "ifupdown", Network Helper often
#    pre-assigns an address to the VLAN interface too (from the config
#    profile), which breaks this heuristic -- confirmed live above.
if [[ -z "${LNG_VLAN_IFACE:-}" ]]; then
  for iface in $(ip -o link show | awk -F': ' '{print $2}' | grep -v '^lo$'); do
    if ! ip -4 -o addr show dev "$iface" | grep -q inet; then
      LNG_VLAN_IFACE="$iface"
      break
    fi
  done
  if [[ -z "${LNG_VLAN_IFACE:-}" ]]; then
    echo "Could not auto-detect the VLAN interface -- every interface already has an IPv4 address." >&2
    if [[ "${LNG_NET_STACK}" == "ifupdown" ]]; then
      echo "This is expected on the ifupdown/Network Helper stack (it pre-assigns an address from the Linode config profile) -- pass --vlan-iface explicitly." >&2
    else
      echo "Pass --vlan-iface explicitly." >&2
    fi
    exit 1
  fi
  echo "Auto-detected VLAN interface: $LNG_VLAN_IFACE (no IPv4 address was configured on it yet)"
fi

VLAN_PREFIX="${LNG_VLAN_IP#*/}"
if [[ "$VLAN_PREFIX" == "$LNG_VLAN_IP" ]]; then
  echo "--vlan-ip must include a prefix, e.g. 192.168.100.251/22" >&2
  exit 1
fi
VLAN_ADDR="${LNG_VLAN_IP%%/*}"

# 2a. Collision preflight -- roadmap/M20-remove-terraform-client-creation.md.
#     Now that Terraform no longer allocates client VLAN addresses
#     (static_vlan_slot, removed), there's no central registry to check
#     --vlan-ip against, and natctl's own roster only knows about fleet
#     nodes, not other clients, so it can't catch a collision with
#     another client either. An ARP probe directly against the VLAN
#     segment catches BOTH cases at the one moment it actually matters.
#     Grounded in a real incident, not a hypothetical one: a manually
#     picked --vlan-ip that happened to already be a live floor node's
#     own address, with nothing catching it before applying (confirmed
#     live, 2026-09-02).
#
#     Skipped entirely if this interface already owns this exact
#     address -- this script is safe to re-run, and probing for an
#     address the LOCAL interface already has would see its own reply
#     and falsely report a collision on every re-run, which would be a
#     real regression to the "safe to re-run" guarantee, not a safety
#     improvement.
if ip -4 -o addr show dev "${LNG_VLAN_IFACE}" | awk '{print $4}' | grep -qx "${LNG_VLAN_IP}"; then
  echo "${LNG_VLAN_IP} is already configured on ${LNG_VLAN_IFACE} -- skipping the collision preflight (this looks like a re-run, not a fresh assignment)."
elif command -v arping >/dev/null 2>&1; then
  echo "Checking whether ${VLAN_ADDR} is already in use on ${LNG_VLAN_IFACE}..."
  # -D: duplicate-address-detection mode -- exits 0 if the address does
  # NOT appear to be in use (safe), non-zero if something else on the
  # segment answered for it. -q: quiet. -c: probe count. -w: max wait,
  # seconds.
  if ! arping -D -q -c 3 -w 3 -I "${LNG_VLAN_IFACE}" "${VLAN_ADDR}"; then
    echo "ERROR: ${VLAN_ADDR} already appears to be in use on ${LNG_VLAN_IFACE} -- another host on this VLAN segment (a NAT node or another client) answered for it. Pick a different --vlan-ip and re-run." >&2
    exit 1
  fi
  echo "No response for ${VLAN_ADDR} -- safe to use."
else
  echo "WARNING: 'arping' not found -- skipping the VLAN-IP collision preflight check. Install iputils-arping (or this distro's equivalent package) to enable it, or double-check ${VLAN_ADDR} isn't already in use yourself (e.g. 'linode-cli vlans list' cross-referenced against each member's ipam_address) before proceeding." >&2
fi

# 3. Static address on the VLAN interface -- applied immediately either
#    way; durable persistence differs by stack (see step 8 for
#    "ifupdown", handled at the end of this script rather than here).
if [[ "${LNG_NET_STACK}" == "networkd" ]]; then
  # Auto-detect DNS servers by default if --dns-servers wasn't given --
  # no reason to make every operator look these up by hand. Only the
  # FREE, no-network check runs here: reuse whatever's already
  # configured system-wide in /etc/resolv.conf (skipping the local
  # systemd-resolved stub and loopback, which aren't real upstream
  # resolvers) -- correct whenever some other interface (e.g. VPC DHCP)
  # already has working DNS. The Linode-regions-API fallback does NOT
  # run here -- it needs real internet access to reach api.linode.com,
  # which a "vlan_only"/"vpc_vlan" client doesn't have yet at this point
  # in the script (confirmed live, 2026-09-02: running it here silently
  # failed every time for exactly this client type, the one that needs
  # DNS auto-detection most). That fallback is deferred to step 7,
  # after client-agent/ECMP is up.
  if [[ -z "${LNG_DNS_SERVERS:-}" ]]; then
    echo "No --dns-servers given -- checking other interfaces for existing DNS config..."
    DETECTED="$(LNG_SELF_IFACE="${LNG_VLAN_IFACE}" python3 <<'PYEOF'
import os
import re
import subprocess

self_iface = os.environ["LNG_SELF_IFACE"]
servers = []

# Prefer systemd-resolved's own per-link view over /etc/resolv.conf --
# on a systemd-resolved system, /etc/resolv.conf is almost always just
# the local stub (127.0.0.53), which hides real per-link resolvers
# configured on some OTHER interface. Confirmed live, 2026-09-02: eth0
# (VPC) already had 3 real, working DHCP-provided resolvers visible via
# `resolvectl dns`, invisible to a plain /etc/resolv.conf read -- and
# per this project's own architecture, VPC has no internet route of its
# own anyway (§3.0), so this is genuinely the only reliable local
# source, not just a nice-to-have over the old fallback below.
try:
    out = subprocess.run(
        ["resolvectl", "dns"], capture_output=True, text=True, timeout=5
    ).stdout
    for line in out.splitlines():
        m = re.match(r"\s*Link \d+ \(([^)]+)\):\s*(.*)", line)
        if m and m.group(1) != self_iface and m.group(2).strip():
            servers.extend(m.group(2).split())
except (FileNotFoundError, subprocess.SubprocessError):
    pass

# Fall back to a raw /etc/resolv.conf parse -- non-systemd-resolved
# images, or resolvectl unavailable -- skipping the local stub/loopback.
if not servers:
    try:
        with open("/etc/resolv.conf") as f:
            for line in f:
                line = line.strip()
                if line.startswith("nameserver"):
                    parts = line.split()
                    if len(parts) > 1 and parts[1] not in ("127.0.0.53", "127.0.0.1", "::1"):
                        servers.append(parts[1])
    except FileNotFoundError:
        pass

if servers:
    print(f"SERVERS={','.join(dict.fromkeys(servers))}")
PYEOF
)"
    while IFS='=' read -r key val; do
      [[ "$key" == "SERVERS" ]] && LNG_DNS_SERVERS="$val"
    done <<<"$DETECTED"
    if [[ -n "${LNG_DNS_SERVERS:-}" ]]; then
      echo "Found existing resolvers on another interface: ${LNG_DNS_SERVERS}"
    else
      echo "No usable resolvers found on any other interface -- will retry via the Linode regions API once client-agent/ECMP is up (step 7)." >&2
      LNG_DNS_PENDING_AUTODETECT=1
    fi
  fi

  # The "00-" filename prefix is deliberate, not cosmetic -- Akamai's
  # own network stage writes a competing "05-eth<N>.network" first on
  # some images, and systemd-networkd applies only the lexically-first
  # match (same reasoning as this project's own
  # ansible/cloud-init/client-node.yaml.tftpl).
  mkdir -p /etc/systemd/network
  {
    echo "[Match]"
    echo "Name=${LNG_VLAN_IFACE}"
    echo
    echo "[Network]"
    echo "Address=${VLAN_ADDR}/${VLAN_PREFIX}"
    if [[ -n "${LNG_DNS_SERVERS:-}" ]]; then
      for dns in ${LNG_DNS_SERVERS//,/ }; do
        echo "DNS=${dns}"
      done
      echo "Domains=${LNG_DNS_SEARCH_DOMAIN}"
      echo "DNSDefaultRoute=${LNG_DNS_DEFAULT_ROUTE}"
    fi
  } >/etc/systemd/network/00-lng-vlan.network
  if [[ -z "${LNG_DNS_SERVERS:-}" && -z "${LNG_DNS_PENDING_AUTODETECT:-}" ]]; then
    echo "No --dns-servers given -- leaving DNS unconfigured on ${LNG_VLAN_IFACE}." >&2
    echo "If this client has no other interface providing DNS, hostname lookups will fail even though NAT egress works. See this script's --dns-servers comment for how to look up your region's resolvers." >&2
  fi
  systemctl restart systemd-networkd
  ip addr add "${LNG_VLAN_IP}" dev "${LNG_VLAN_IFACE}" 2>/dev/null || true
  ip link set "${LNG_VLAN_IFACE}" up
else
  # ifupdown/Network Helper: a local file here would just be silently
  # overwritten on next reboot (see step 1's comment) -- apply the
  # address immediately for THIS boot only (flushing whatever address
  # Network Helper pre-assigned, so there's no stale duplicate), and
  # persist it properly via the Linode API in step 8, once client-agent
  # is up and this client actually has a route to the internet.
  if [[ -n "${LNG_DNS_SERVERS:-}" ]]; then
    echo "--dns-servers given but ignored -- Network Helper already manages /etc/resolv.conf correctly on the ifupdown stack." >&2
  fi
  ip addr flush dev "${LNG_VLAN_IFACE}"
  ip addr add "${LNG_VLAN_IP}" dev "${LNG_VLAN_IFACE}"
  ip link set "${LNG_VLAN_IFACE}" up
  echo "Applied ${LNG_VLAN_IP} to ${LNG_VLAN_IFACE} for this boot only -- see this script's final output for how it gets persisted across a reboot."
fi

# 3a. Decide whether client-agent belongs on this instance at all -- see
#     the --force parameter comment above for the full reasoning. Order
#     matters: an already-installed unit (a prior run of this script,
#     forced or not) always wins, so a re-run never flip-flops based on
#     whatever the route table happens to look like at that moment --
#     only the FIRST run's decision (or an explicit --force) matters.
if [[ "${LNG_FORCE}" == "true" ]]; then
  LNG_INSTALL_CLIENT_AGENT=true
  echo "--force given -- installing client-agent regardless of any existing default route."
elif [[ -f /etc/systemd/system/lng-client-agent.service ]]; then
  LNG_INSTALL_CLIENT_AGENT=true
  echo "client-agent is already installed from a previous run of this script -- re-run will update it in place."
elif ip route show default 2>/dev/null | grep -q .; then
  LNG_INSTALL_CLIENT_AGENT=false
  echo "This instance already has a default route via another interface -- client-agent will NOT be installed (nothing for it to manage)."
  echo "Pass --force to install and start it anyway, e.g. for a deliberate dual-path egress policy."
else
  LNG_INSTALL_CLIENT_AGENT=true
  echo "No existing default route found -- installing client-agent to provide one via the NAT fleet."
fi

if [[ "${LNG_INSTALL_CLIENT_AGENT}" == "true" ]]; then

# 4. Fetch the compiled client-agent binary. python3, not curl -- every
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

# 5. Config.
mkdir -p /etc/lng-client-agent
cat >/etc/lng-client-agent/env <<EOF
NATCTL_ROSTER_URL=${LNG_ROSTER_URL}
LNG_PRIVATE_IFACE=${LNG_VLAN_IFACE}
LNG_HEALTH_PROBE_TIMEOUT=${LNG_HEALTH_PROBE_TIMEOUT}
LNG_DRY_RUN=false
LNG_FALLBACK_PROBE_ENABLED=${LNG_FALLBACK_PROBE_ENABLED}
LNG_FALLBACK_PROBE_INTERVAL=${LNG_FALLBACK_PROBE_INTERVAL}
EOF

# 6. systemd unit -- static, non-secret content, embedded directly
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

# 7. Last-resort DNS auto-detection via the Linode regions API, only
#    reached if step 3 found NOTHING on any other interface (e.g. a
#    genuinely resolver-less "vlan_only" client with no VPC interface
#    at all). Deferred to here, after client-agent/ECMP is up, for the
#    same chicken-and-egg reason as step 8 below. NOTE: this can still
#    fail even now -- resolving api.linode.com itself needs a working
#    resolver, which is exactly what this interface doesn't have yet;
#    confirmed live, 2026-09-02, that it doesn't reliably succeed even
#    with client-agent's ECMP route up. Self-identifies this instance's
#    region via the Metadata Service (link-local, no internet/token
#    needed for that half) then, if it works, rewrites the same
#    00-lng-vlan.network file with the resolved DNS lines added and
#    restarts systemd-networkd once more to apply them.
if [[ "${LNG_NET_STACK}" == "networkd" && -n "${LNG_DNS_PENDING_AUTODETECT:-}" ]]; then
  echo "Retrying DNS auto-detection via the Linode regions API now that client-agent/ECMP is up..."
  DETECTED="$(python3 <<'PYEOF'
import json
import sys
import urllib.request

try:
    treq = urllib.request.Request(
        "http://169.254.169.254/v1/token", method="PUT",
        headers={"Metadata-Token-Expiry-Seconds": "60"},
    )
    with urllib.request.urlopen(treq, timeout=5) as r:
        mtoken = r.read().decode().strip()
    req = urllib.request.Request(
        "http://169.254.169.254/v1/instance",
        headers={"Metadata-Token": mtoken},
    )
    with urllib.request.urlopen(req, timeout=5) as r:
        region = json.load(r)["region"]
    with urllib.request.urlopen(
        f"https://api.linode.com/v4/regions/{region}", timeout=15
    ) as r:
        resolvers = json.load(r)["resolvers"]["ipv4"]
    servers = [ip.strip() for ip in resolvers.split(",") if ip.strip()]
    if servers:
        print(f"SERVERS={','.join(servers)}")
except Exception as e:
    print(f"ERROR={e}", file=sys.stderr)
PYEOF
)"
  while IFS='=' read -r key val; do
    [[ "$key" == "SERVERS" ]] && LNG_DNS_SERVERS="$val"
  done <<<"$DETECTED"
  if [[ -n "${LNG_DNS_SERVERS:-}" ]]; then
    echo "Auto-detected DNS servers via the Linode API: ${LNG_DNS_SERVERS}"
    {
      echo "[Match]"
      echo "Name=${LNG_VLAN_IFACE}"
      echo
      echo "[Network]"
      echo "Address=${VLAN_ADDR}/${VLAN_PREFIX}"
      for dns in ${LNG_DNS_SERVERS//,/ }; do
        echo "DNS=${dns}"
      done
      echo "Domains=${LNG_DNS_SEARCH_DOMAIN}"
      echo "DNSDefaultRoute=${LNG_DNS_DEFAULT_ROUTE}"
    } >/etc/systemd/network/00-lng-vlan.network
    systemctl restart systemd-networkd
    echo "DNS applied to ${LNG_VLAN_IFACE}."
  else
    echo "WARNING: DNS auto-detection still failed (regions API unreachable or timed out) -- ${LNG_VLAN_IFACE} has no DNS resolver configured. Pass --dns-servers explicitly, or re-run this script once internet egress is confirmed working." >&2
  fi
fi

# 8. Persist the VLAN address for the ifupdown/Network Helper stack.
#    Deferred to here, after client-agent/ECMP is up, because a
#    "vlan_only"/"vpc_vlan" client has no internet path of its own until
#    client-agent brings one up -- calling api.linode.com any earlier
#    would hit the exact same chicken-and-egg failure step 4's
#    client-agent fetch already works around. Network Helper regenerates
#    /etc/network/interfaces from the Linode config profile on every
#    boot (see step 1), so the only durable fix is updating the
#    profile's own ipam_address via the API -- the same mechanism
#    Terraform already uses for floor nodes.
if [[ "${LNG_NET_STACK}" == "ifupdown" ]]; then
  if [[ -z "${LNG_LINODE_API_TOKEN:-}" ]]; then
    echo "WARNING: --linode-api-token not given -- ${LNG_VLAN_IP} on ${LNG_VLAN_IFACE} will revert to this instance's config-profile address on next reboot." >&2
    echo "To persist it: set the VLAN interface's IPAM address to ${LNG_VLAN_IP} on this Linode's config profile (Cloud Manager, or 'linode-cli linodes config-update'), or re-run this script with --linode-api-token." >&2
  else
    echo "Persisting ${LNG_VLAN_IP} on ${LNG_VLAN_IFACE} via the Linode API (config profile ipam_address)..."
    if LNG_TOKEN="${LNG_LINODE_API_TOKEN}" LNG_TARGET_IP="${LNG_VLAN_IP}" python3 - <<'PYEOF'
import json
import os
import sys
import time
import urllib.request

token = os.environ["LNG_TOKEN"]
vlan_ip = os.environ["LNG_TARGET_IP"]


def metadata_get(path):
    treq = urllib.request.Request(
        "http://169.254.169.254/v1/token",
        method="PUT",
        headers={"Metadata-Token-Expiry-Seconds": "60"},
    )
    with urllib.request.urlopen(treq, timeout=5) as r:
        mtoken = r.read().decode().strip()
    req = urllib.request.Request(
        f"http://169.254.169.254/v1{path}",
        headers={"Metadata-Token": mtoken},
    )
    with urllib.request.urlopen(req, timeout=5) as r:
        return json.load(r)


def api(path, method="GET", body=None):
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(
        f"https://api.linode.com/v4{path}",
        data=data,
        method=method,
        headers={
            "Authorization": f"Bearer {token}",
            "Content-Type": "application/json",
        },
    )
    with urllib.request.urlopen(req, timeout=15) as r:
        return json.load(r)


last_err = None
for attempt in range(5):
    try:
        lid = metadata_get("/instance")["id"]
        configs = api(f"/linode/instances/{lid}/configs")["data"]
        cfg = configs[0]
        interfaces = cfg["interfaces"]
        vlan_idx = next(
            i for i, ifc in enumerate(interfaces) if ifc.get("purpose") == "vlan"
        )
        interfaces[vlan_idx]["ipam_address"] = vlan_ip
        api(
            f"/linode/instances/{lid}/configs/{cfg['id']}",
            method="PUT",
            body={"interfaces": interfaces},
        )
        print(f"Config profile updated: eth{vlan_idx} ipam_address={vlan_ip}")
        sys.exit(0)
    except Exception as e:
        last_err = e
        time.sleep(5)
print(f"Failed after 5 attempts: {last_err}", file=sys.stderr)
sys.exit(1)
PYEOF
    then
      echo "Persisted -- ${LNG_VLAN_IP} on ${LNG_VLAN_IFACE} will now survive a reboot."
    else
      echo "WARNING: could not persist ${LNG_VLAN_IP} via the API -- it will revert to this instance's config-profile address on next reboot. Set it manually (Cloud Manager, or 'linode-cli linodes config-update'), or re-run this script once network egress is confirmed working." >&2
    fi
  fi
fi

if [[ "${LNG_INSTALL_CLIENT_AGENT}" == "true" ]]; then
  echo "Done. client-agent installed and started on ${LNG_VLAN_IFACE} (${LNG_VLAN_IP})."
  echo "Verify with:"
  echo "  ip route"
  echo "  journalctl -u lng-client-agent -f"
else
  echo "Done. ${LNG_VLAN_IP} applied to ${LNG_VLAN_IFACE} -- client-agent was NOT installed, since this instance already has its own default route (pass --force to install it anyway)."
fi
echo "  curl -s https://ifconfig.me"

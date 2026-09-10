#!/usr/bin/env bash
# configure-vlan-address.sh (scripts)
#
# Applies a persistent static address to an already-attached VLAN
# interface on an existing Linode -- the first of two separate steps for
# turning a server into a NAT gateway client (see
# install-nat-client.sh for the second: setting up NAT routing itself).
# Split into two scripts, 2026-09-10, from what was previously a single
# combined install-nat-client.sh -- VLAN addressing and NAT routing are
# genuinely separate concerns (a client's address doesn't change when
# its routing does, and vice versa), and conflating them made it easy to
# assume this script's safety features (the ARP-probe collision check,
# reboot persistence) were "just NAT routing setup" rather than a
# standalone, reusable capability in their own right.
#
# Does NOT attach the VLAN interface itself -- that's a Linode
# account-level action (Cloud Manager, or `linode-cli linodes
# interface-add --vlan.vlan_label <label> --vlan.ipam_address <cidr>`,
# power the instance off first if replacing an existing interface). This
# script only configures what's already attached, and does not choose
# the address for you either -- see --vlan-ip below.
#
# -----------------------------------------------------
# Two ways to run this:
#
# 1) MANUALLY, on an already-running server, as root, with flags:
#
#    ./configure-vlan-address.sh --vlan-ip 192.168.100.251/22
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
#    export LNG_VLAN_IP="192.168.100.251/22"
#    # ... paste the rest of configure-vlan-address.sh's body from the
#    # "set -euo pipefail" line down ...
#
#    The instance still needs its VLAN interface attached BEFORE first
#    boot (set that up wherever you create the instance -- Cloud
#    Manager, Terraform, `linode-cli linodes create`) -- user-data alone
#    can't attach a network interface to itself. Run
#    install-nat-client.sh afterward (a second user-data script, or a
#    separate manual step) to actually set up NAT routing.
#
# -----------------------------------------------------
# Parameters (flag / equivalent env var):
#
# 1) --vlan-ip <cidr> / LNG_VLAN_IP (required)
#      This instance's own static address on the pool's VLAN, e.g.
#      192.168.100.251/22. Must not collide with any floor/elastic node
#      or another client on the same VLAN -- there is no reservation
#      system for manually-attached clients like this one, unlike
#      Terraform's client_groups static_vlan_slot mechanism (removed,
#      see roadmap/M20-remove-terraform-client-creation.md), so pick it
#      from your pool's reserved static-client window
#      (client_static_vlan_reserved in terraform.tfvars). This script's
#      own ARP-probe collision check (below) is a last-moment safety
#      net, not a substitute for picking from the right range.
#
# 2) --vlan-iface <name> / LNG_VLAN_IFACE (optional)
#      Which network interface is the VLAN one. If omitted, this script
#      auto-detects it as the first non-loopback interface with no IPv4
#      address currently assigned (Linode auto-configures VPC interfaces
#      via DHCP at boot but never does this for VLAN interfaces -- so an
#      addressless interface is a reliable signal on a freshly-attached
#      instance). Auto-detection can guess wrong on an instance with
#      other unconfigured interfaces for unrelated reasons -- the script
#      prints what it picked before using it; pass this flag explicitly
#      if that's ever not right. IMPORTANT: on the "ifupdown" network
#      stack (see --linode-api-token below) this heuristic often FAILS,
#      because Linode's own Network Helper pre-assigns the config
#      profile's IPAM address to the VLAN interface before this script
#      ever runs -- confirmed live, 2026-09-02, on a Debian 12 test
#      client. Pass this flag explicitly on that stack.
#
# 3) --linode-api-token <token> / LNG_LINODE_API_TOKEN (optional, but
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
#      immediately) but reverts on the next reboot. Only needs
#      read/write access to Linode Instances -- scope it narrowly. Never
#      pass this on the command line on a shared/logged shell -- prefer
#      the LNG_LINODE_API_TOKEN env var, and see this repo's own
#      credential-handling convention (CLAUDE.md) either way.
#      Found live 2026-09-10: this script cannot verify whether an
#      address is ALREADY the config profile's own value without a
#      token (reading it needs the same credential as writing it) -- if
#      you've already set this address some other way (Cloud Manager,
#      linode-cli, or a prior run with this token), the warning printed
#      without one is a false positive, not a guarantee of data loss.
#
# 4) --dns-servers "<ip1>,<ip2>,..." / LNG_DNS_SERVERS (optional, comma-
#      or space-separated)
#      A "vlan_only"/"vpc_vlan" client has no public interface, so it
#      never gets the DNS resolvers Linode's own cloud-init/DHCP normally
#      writes for eth0 -- left unconfigured, IP-based egress through the
#      NAT fleet still works (once install-nat-client.sh has run), but
#      every hostname-based connection (curl to a domain, apt, etc.)
#      fails. AUTO-DETECTED BY DEFAULT on the "systemd-networkd" stack if
#      this flag is omitted: first reuses whatever's already configured
#      on another interface (e.g. a working VPC-DHCP-provided resolver),
#      and if nothing usable is found there, tries Linode's own regions
#      API directly (self-identifying this instance's region via the
#      Metadata Service, no auth needed for the regions lookup itself;
#      see https://techdocs.akamai.com/cloud-computing/docs/dns-resolvers).
#      That second attempt needs real internet access, which a freshly
#      VLAN-only instance doesn't have until install-nat-client.sh has
#      also been run -- if it fails for that reason, this script is safe
#      to re-run afterward to pick up DNS once routing exists. Pass this
#      flag explicitly to override auto-detection (e.g. you know your
#      resolvers already, or auto-detection picked something wrong).
#      IGNORED on the "ifupdown" network stack either way -- Network
#      Helper already generates a correct /etc/resolv.conf there on
#      every boot, confirmed live on the same Debian 12 test client.
#
# 5) --dns-search-domain <domain> / LNG_DNS_SEARCH_DOMAIN
#      (optional, default "members.linode.com")
# 6) --dns-default-route true|false / LNG_DNS_DEFAULT_ROUTE
#      (optional, default "true" -- this interface is usually the only
#      one with any DNS config on a private-only client, so it should
#      also be the one systemd-resolved routes lookups through)
#
# -----------------------------------------------------
# Best Practices:
#
# - Safe to re-run -- every step here is idempotent (overwrites its own
#   config files; the ARP-probe collision check is itself skipped, not
#   falsely triggered, if this interface already owns the exact address).
# - Run install-nat-client.sh next to actually route traffic through the
#   NAT fleet -- this script only applies an address, it does not set up
#   any routing on its own.
# - After running, confirm with:
#     ip -4 -o addr show dev <iface>   # the address you asked for
#     ping -c1 <a NAT node's VLAN IP>  # basic L2 reachability
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
    --vlan-ip) LNG_VLAN_IP="$2"; shift 2 ;;
    --vlan-iface) LNG_VLAN_IFACE="$2"; shift 2 ;;
    --linode-api-token) LNG_LINODE_API_TOKEN="$2"; shift 2 ;;
    --dns-servers) LNG_DNS_SERVERS="$2"; shift 2 ;;
    --dns-search-domain) LNG_DNS_SEARCH_DOMAIN="$2"; shift 2 ;;
    --dns-default-route) LNG_DNS_DEFAULT_ROUTE="$2"; shift 2 ;;
    *) echo "Unknown arg: $1" >&2; exit 1 ;;
  esac
done

: "${LNG_VLAN_IP:?--vlan-ip (or LNG_VLAN_IP) is required, e.g. 192.168.100.251/22}"
LNG_DNS_SEARCH_DOMAIN="${LNG_DNS_SEARCH_DOMAIN:-members.linode.com}"
LNG_DNS_DEFAULT_ROUTE="${LNG_DNS_DEFAULT_ROUTE:-true}"

if [[ "$(id -u)" -ne 0 ]]; then
  echo "Must run as root." >&2
  exit 1
fi

# This script configures a Linux network stack directly -- it must run
# ON the target client instance itself, not on whatever machine is
# driving your automation. Caught live, 2026-09-08 (on
# install-nat-client.sh before this split): run on macOS, a Linux-only
# sysctl this project's sibling script depends on fails with a cryptic
# BSD "unknown oid" error that reads like a target-side problem, when
# the real issue is just the wrong host running it. Fail fast with an
# actionable message instead.
if [[ "$(uname -s)" != "Linux" ]]; then
  echo "This script must run on the Linux client instance itself (detected: $(uname -s))." >&2
  echo "SSH into the target Linode and run it there, or deliver it as that instance's own user-data -- see the usage comment at the top of this file." >&2
  exit 1
fi

# 1. Detect which network stack manages this image's interfaces --
#    systemd-networkd (newer "linode"-interface-generation images with
#    no Network Helper running) accepts a plain drop-in .network file;
#    classic config-profile images instead use ifupdown, with Linode's
#    own "Network Helper" fully REGENERATING /etc/network/interfaces
#    (and /etc/resolv.conf) from the Linode config profile on every
#    single boot -- confirmed live, 2026-09-02, on a Debian 12 test
#    client. A local file is a no-op on that stack; see step 5.
if systemctl is-active --quiet systemd-networkd 2>/dev/null; then
  LNG_NET_STACK="networkd"
else
  LNG_NET_STACK="ifupdown"
fi
echo "Detected network stack: ${LNG_NET_STACK}"

# Tracked purely for the "Summary of changes" block at the very end --
# never read/branched on anywhere else. systemd-networkd's own drop-in
# file (step 3 below) is durable on its own, no API call needed.
if [[ "${LNG_NET_STACK}" == "networkd" ]]; then
  LNG_VLAN_PERSIST_STATUS="yes (systemd-networkd drop-in file, no API call needed)"
else
  LNG_VLAN_PERSIST_STATUS="unknown -- --linode-api-token not given (see step 5 below)"
fi

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
#    way; durable persistence differs by stack (see step 5 for
#    "ifupdown").
if [[ "${LNG_NET_STACK}" == "networkd" ]]; then
  # Auto-detect DNS servers by default if --dns-servers wasn't given --
  # no reason to make every operator look these up by hand. First tries
  # the FREE, no-network check: reuse whatever's already configured
  # system-wide (skipping the local systemd-resolved stub and loopback,
  # which aren't real upstream resolvers) -- correct whenever some other
  # interface (e.g. VPC DHCP) already has working DNS. If that finds
  # nothing, falls straight through to the Linode regions API -- which
  # needs real internet access, so it can fail on a genuinely
  # "vlan_only"/"vpc_vlan" client that hasn't run install-nat-client.sh
  # yet (confirmed live, 2026-09-02) -- caught with a bounded timeout,
  # falling back to "leave DNS unconfigured" with an explicit warning
  # telling you to re-run this script once routing is up.
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
# own anyway, so this is genuinely the only reliable local source, not
# just a nice-to-have over the old fallback below.
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
      echo "Nothing found locally -- trying the Linode regions API (needs real internet access, may fail on a freshly VLAN-only instance)..."
      DETECTED="$(timeout 20 python3 <<'PYEOF'
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
        f"https://api.linode.com/v4/regions/{region}", timeout=10
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
      fi
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
  if [[ -z "${LNG_DNS_SERVERS:-}" ]]; then
    echo "No DNS resolvers configured on ${LNG_VLAN_IFACE}." >&2
    echo "If this client has no other interface providing DNS, hostname lookups will fail even once NAT egress works. Re-run this script once install-nat-client.sh has set up routing, or pass --dns-servers explicitly." >&2
  fi
  systemctl restart systemd-networkd
  ip addr add "${LNG_VLAN_IP}" dev "${LNG_VLAN_IFACE}" 2>/dev/null || true
  ip link set "${LNG_VLAN_IFACE}" up
else
  # ifupdown/Network Helper: a local file here would just be silently
  # overwritten on next reboot (see step 1's comment) -- apply the
  # address immediately for THIS boot only (flushing whatever address
  # Network Helper pre-assigned, so there's no stale duplicate), and
  # persist it properly via the Linode API in step 5.
  if [[ -n "${LNG_DNS_SERVERS:-}" ]]; then
    echo "--dns-servers given but ignored -- Network Helper already manages /etc/resolv.conf correctly on the ifupdown stack." >&2
  fi
  ip addr flush dev "${LNG_VLAN_IFACE}"
  ip addr add "${LNG_VLAN_IP}" dev "${LNG_VLAN_IFACE}"
  ip link set "${LNG_VLAN_IFACE}" up
  echo "Applied ${LNG_VLAN_IP} to ${LNG_VLAN_IFACE} for this boot only -- see this script's final output for how it gets persisted across a reboot."
fi

# 5. Persist the VLAN address for the ifupdown/Network Helper stack.
#    Network Helper regenerates /etc/network/interfaces from the Linode
#    config profile on every boot (see step 1), so the only durable fix
#    is updating the profile's own ipam_address via the API -- the same
#    mechanism Terraform already uses for floor nodes. Unlike
#    install-nat-client.sh's own former version of this step, there is
#    no chicken-and-egg reason to defer this to "after routing is up"
#    anymore -- this script makes no claim about this instance's
#    internet access at all, so it just runs the API call directly here.
if [[ "${LNG_NET_STACK}" == "ifupdown" ]]; then
  if [[ -z "${LNG_LINODE_API_TOKEN:-}" ]]; then
    # This used to assert "will revert" as a certainty, but without a
    # token this script has no way to actually read the config profile's
    # current ipam_address -- reading it needs the exact same credential
    # as writing it, so there's no free check. If you already set this
    # address on the config profile some other way (Cloud Manager,
    # linode-cli, or a prior --linode-api-token run), this warning is a
    # false positive and reboot will be fine -- it's phrased as a
    # possibility, not a guarantee, for exactly that reason.
    echo "WARNING: --linode-api-token not given -- cannot verify whether ${LNG_VLAN_IP} on ${LNG_VLAN_IFACE} is already the config profile's own address. If it isn't, it will revert on next reboot; if it already is (set some other way), this warning is a false positive and nothing further is needed." >&2
    echo "To persist it (or confirm it's already persisted): set the VLAN interface's IPAM address to ${LNG_VLAN_IP} on this Linode's config profile (Cloud Manager, or 'linode-cli linodes config-update'), or re-run this script with --linode-api-token." >&2
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
      LNG_VLAN_PERSIST_STATUS="yes (config profile ipam_address updated via API)"
    else
      echo "WARNING: could not persist ${LNG_VLAN_IP} via the API -- it will revert to this instance's config-profile address on next reboot. Set it manually (Cloud Manager, or 'linode-cli linodes config-update'), or re-run this script once network egress is confirmed working." >&2
      LNG_VLAN_PERSIST_STATUS="no -- API update failed, will revert on reboot (see warning above)"
    fi
  fi
fi

echo ""
echo "===== Summary of changes ====="
echo "VLAN address:    ${LNG_VLAN_IP} on ${LNG_VLAN_IFACE}"
echo "Persisted across reboot: ${LNG_VLAN_PERSIST_STATUS}"
if [[ -n "${LNG_DNS_SERVERS:-}" ]]; then
  echo "DNS resolvers:    ${LNG_DNS_SERVERS} (search domain: ${LNG_DNS_SEARCH_DOMAIN})"
else
  echo "DNS resolvers:    none configured"
fi
echo "==============================="
echo ""
echo "Next: run install-nat-client.sh to set up NAT routing through the fleet."
echo "Verify this step with:"
echo "  ip -4 -o addr show dev ${LNG_VLAN_IFACE}"

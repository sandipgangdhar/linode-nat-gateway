<!--
README.md (acceptance-tests)

What this suite is, how it's organized, prerequisites, how to run it
(all of it or one check at a time), and an honest read of which checks
are safe for routine use vs. which are deliberately disruptive/expensive
and should be run only in a maintenance window or a deliberate
validation pass.

Author: Sandip Gangdhar (https://github.com/sandipgangdhar)
(c) Linode-NAT-Gateway (LNG) | Developed by Sandip Gangdhar | 2026
-->

# LNG acceptance-test suite

Automated, post-deploy validation of a real LNG deployment — the six checks below are what turns "Terraform apply succeeded" into "this fleet actually does what the README claims it does," end to end: roster/health, real NAT egress, buddy/conntrack failover, live BGP IP failover with a zero-packet-loss bar, autoscaling, and full NAT observability. This is a genuine test harness, not a mock — every check makes real network calls against a real deployment (SSH, HTTP, ICMP). It does nothing on its own; you point it at a deployment via `config.yaml` and run it.

## Prerequisites

```bash
pip install -r ../controller/requirements.txt   # requests + PyYAML, already this project's own dependencies
cp config.example.yaml config.yaml
# edit config.yaml with your real deployment's endpoints/hosts/credentials
```

- SSH access (key-based, matching `ssh.user`/`ssh.key_path` in `config.yaml`) from wherever this suite runs to: the private client instance(s) used by checks 02/05, and the NAT node(s) targeted by checks 03/04.
- Real internet reachability from wherever this suite runs, for check 04's `ping` against a public IP.
- `hey` (https://github.com/rakyll/hey) installed on the client instance used by check 05 — see `scripts/loadtest.sh`'s own prerequisites.
- Terraform's own `outputs.tf` gives you `roster_url_*`, `grafana_url`, and `prometheus_url` directly (`terraform output`) — see `terraform/environments/example/outputs.tf`.

## Running it

```bash
python run_acceptance_tests.py                 # everything configured in config.yaml
python run_acceptance_tests.py --list          # see every discovered check's ID and description
python run_acceptance_tests.py --only 01-roster-and-health --only 06-observability
```

Exit code is 0 only if every check that ran passed (SKIPs don't count against you — see "What SKIP means" below). A summary table prints at the end either way.

## The six checks, in the order they run

| # | Check ID | What it proves | Disruption / cost |
|---|---|---|---|
| 1 | `01-roster-and-health` | natctl's roster is reachable; each pool has enough healthy nodes | None — read-only |
| 2 | `02-nat-egress` | A private client instance's egress IP is genuinely one of this pool's own NAT node IPs | None — read-only |
| 3 | `03-buddy-failover-drill` | An unhealthy node is routed around, then rejoins cleanly | Brief — stops `nat-exporter` on a real node |
| 4 | `04-ip-failover-bgp` | Killing FRR on a buddy-paired node produces **zero** ping loss to its public IP, both directions | Real — stops `frr` (and this node's BGP-advertised IP) on a real node |
| 5 | `05-autoscale` | A real load spike causes natctl to provision an additional elastic node | Expensive — provisions a real billable Linode |
| 6 | `06-observability` | Prometheus/Grafana/Alertmanager are up, with real NAT data | None — read-only |

Each check's own file header (`checks/check_NN_*.py`) has the full detail on exactly what it does and why.

## What SKIP means

A check SKIPs a pool (rather than failing it) when that pool's `config.yaml` block is missing the specific keys that check needs — most commonly because you deliberately left out a `node_failure_drill` / `ip_failover_drill` / `autoscale_drill` block for a pool you don't want that particular drill run against right now. SKIP is not a warning sign by itself; it's this suite respecting that not every check makes sense for every pool, every time.

## Honest guidance on which checks to run when

Checks 01, 02, and 06 are read-only and safe to run on every deploy, or even wire into a recurring health check. Checks 03 and 04 are real drills against real infrastructure — brief but genuinely disruptive; run them in a scheduled maintenance window, not as a routine gate. Check 05 provisions a real, billable Linode — it's opt-in by design (leave `autoscale_drill` out of a pool's config to skip it entirely) and should be run deliberately, not by accident.

None of these checks were run as part of preparing this suite — see the repo's own commit history and `docs/RUNBOOK.md` for the deployment sequence this suite is meant to run after, not before.

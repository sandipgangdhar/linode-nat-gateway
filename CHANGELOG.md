## [v0.3.0] - 2025-11-13
### Added
- End-to-end HA NAT stack with **Keepalived + nftables + conntrackd + lelastic**.
- **Node Exporter** + textfile collector for NAT-HA metrics.
- **Validation playbook** (failover probe, FIP checks, SNAT rule verification).
- **lelastic wrapper** to switch primary/secondary mode via keepalived notify.

### Changed
- Deterministic LAN CIDR auto-detect for nftables template.
- Stronger systemd unit ordering; reliable reloads on config changes.
- Safer Ansible idempotency around downloads, tar extraction & handlers.

### Fixed
- Node exporter tarball handling & unit start-order.
- conntrackd config syntax and FTFW filter placement.
- Keepalived start-condition “unmet” after fresh boots.

### Docs
- **Quick Deployment** steps updated (TF var export, tfvars flow).
- Clarified **VLAN + Linode Cloud Firewall** scope and notes.

**Upgrade notes:**  
- Ensure `TF_VAR_linode_token` is exported before `terraform apply`.  
- Re-run `ansible/site.yml` to install `lelastic-wrapper` + notify hooks.

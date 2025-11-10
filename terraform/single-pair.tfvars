region                = "in-maa"
vlan_label            = "private-lan"
nat_a_vlan_ip         = "192.168.1.3/24"
nat_b_vlan_ip         = "192.168.1.4/24"
placement_group_label = "NAT"
ssh_authorized_keys = [
  "ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABgQC/Ezlu9Q7psgXPihYJRvxAhbiMcAzwDcDaIEcv4GIOPMV9vskpoWAN4RZmPStcmZLsNj4u1nCstgBxlYv253nMD0t3t67vCRkpgmlPlbM61RWbDT0NlRBg9u4MDyhhWleh6G/neN/JaHjUdEhrbAt0Y6W9mPElsmm0CopBci9fRUpG/cEoAQV67Ehjeu01NmqmyzWcOHQ1HMcnEM9DzdPneXuCPJIFK6dAfOfpzBMwxE3e6Qu1xLcgRufNiIIDXYqKyqZElLx1pAAu/pNtJJ7PLTEG74RLhwMYMVQh1X4VIhykE2giNxXpf3glzlDNDybRWTdIe9jO49pvPMb+GrXrgH4syEsE9mtV/q4V/0lhs0UYxPlIraoBcvmqXwo7S1vmfggMiD7MlN/Q3PjFWyJTPP/ifo55HtLGx5iIKOmShMjOXpFIKjJerdw6DEX566ezggex66//nPqgeNgkk0lvmtCmt0NvdAzKQ+FlbYQqiKpp2bwvy3TxObIKcMa6d2k= sgangdha@blr-mp9vq"
]
# --- New: the Linode ID that OWNS that IP (the “anchor” Linode) ---
# If you want to include the anchor in the share list (recommended), set the ID here.
# If you prefer not to include it, set 0.
anchor_linode_id = 86776804 # <— replace with the actual Linode ID (or 0)

# --- New: enable the /share call so nat-a & nat-b can use the IP ---
use_ip_share = true

# the additional public IPv4 from Support has provied which we will use as a shared ip
shared_ipv4 = "172.236.95.221"

# "Floating VLAN IP (VIP) used as the default gateway for NAT traffic, e.g., 172.16.0.1/24
vlan_vip = "192.168.1.1/24"

# Linode DCID for lelastic (in-maa = 25) 
# https://techdocs.akamai.com/cloud-computing/docs/configure-failover-on-a-compute-instance#ip-sharing-availability
dcid = 25

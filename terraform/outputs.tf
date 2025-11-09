output "nat_a_ip" {
  description = "Public IP used for NAT-a gateway"
  value       = tolist(linode_instance.nat_a.ipv4)[0]
}

output "nat_b_ip" {
  description = "Public IP used for NAT-b gateway"
  value       = tolist(linode_instance.nat_b.ipv4)[0]
}

output "nat_a_id" {
  description = "Linode instance ID for NAT-a gateway"
  value       = linode_instance.nat_a.id
}

output "nat_b_id" {
  description = "Linode instance ID for NAT-b gateway"
  value       = linode_instance.nat_b.id
}

output "ssh_nat_a" {
  description = "SSH command for NAT-a gateway"
  value       = "ssh root@${tolist(linode_instance.nat_a.ipv4)[0]}"
}

output "ssh_nat_b" {
  description = "SSH command for NAT-b gateway"
  value       = "ssh root@${tolist(linode_instance.nat_b.ipv4)[0]}"
}

output "vlan_vip" {
  description = "Floating VLAN IP used by Keepalived for NAT gateway"
  value       = var.vlan_vip
}

output "shared_ipv4" {
  description = "Additional public IPv4 used for egress"
  value       = var.shared_ipv4
}

output "nat_a_vlan_ip" {
  value = trimsuffix(var.nat_a_vlan_ip, "/24")
}

output "nat_b_vlan_ip" {
  value = trimsuffix(var.nat_b_vlan_ip, "/24")
}

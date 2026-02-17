locals {
  instance_public_ip       = try(data.oci_core_vnic.primary_vnic.public_ip_address, "")
  instance_private_ip      = try(data.oci_core_vnic.primary_vnic.private_ip_address, "")
  ssh_private_key_location = length(trimspace(var.ssh_private_key_path_hint)) > 0 ? var.ssh_private_key_path_hint : "<path-to-private-key>"
}

output "instance_ocid" {
  description = "OCID of the created compute instance."
  value       = oci_core_instance.a1.id
}

output "ad_used" {
  description = "Availability Domain where the instance was created."
  value       = oci_core_instance.a1.availability_domain
}

output "public_ip" {
  description = "Public IPv4 address of the instance primary VNIC."
  value       = local.instance_public_ip
}

output "private_ip" {
  description = "Private IPv4 address of the instance primary VNIC."
  value       = local.instance_private_ip
}

output "ssh_command_powershell" {
  description = "Ready-to-run SSH command for Windows PowerShell."
  value       = local.instance_public_ip != "" ? "ssh -i \"${local.ssh_private_key_location}\" ubuntu@${local.instance_public_ip}" : "Public IP not available. Verify assign_public_ip=true and subnet routing/security rules."
}

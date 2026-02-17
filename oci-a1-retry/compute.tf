locals {
  selected_image_id = var.image_ocid_override != null ? var.image_ocid_override : try(data.oci_core_images.ubuntu_2404[0].images[0].id, null)
}

data "oci_core_images" "ubuntu_2404" {
  count                    = var.image_ocid_override == null ? 1 : 0
  compartment_id           = var.compartment_ocid
  operating_system         = var.image_operating_system
  operating_system_version = var.image_operating_system_version
  shape                    = var.shape
  sort_by                  = "TIMECREATED"
  sort_order               = "DESC"
}

resource "oci_core_instance" "a1" {
  compartment_id      = var.compartment_ocid
  availability_domain = var.availability_domain
  shape               = var.shape
  display_name        = "${var.name_prefix}-instance"

  shape_config {
    ocpus         = var.ocpus
    memory_in_gbs = var.memory_in_gbs
  }

  create_vnic_details {
    subnet_id       = oci_core_subnet.main.id
    assign_public_ip = var.assign_public_ip
    display_name    = "${var.name_prefix}-vnic"
    hostname_label  = "a1host"
  }

  source_details {
    source_type = "image"
    source_id   = local.selected_image_id
  }

  metadata = {
    ssh_authorized_keys = trim(var.ssh_public_key)
  }

  lifecycle {
    precondition {
      condition     = local.selected_image_id != null && length(trim(local.selected_image_id)) > 0
      error_message = "No compatible Ubuntu 24.04 image found for VM.Standard.A1.Flex. Use image_ocid_override to pin a valid image OCID."
    }
  }
}

data "oci_core_vnic_attachments" "instance_vnics" {
  compartment_id = var.compartment_ocid
  instance_id    = oci_core_instance.a1.id
}

data "oci_core_vnic" "primary_vnic" {
  vnic_id = data.oci_core_vnic_attachments.instance_vnics.vnic_attachments[0].vnic_id
}

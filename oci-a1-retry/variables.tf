variable "compartment_ocid" {
  description = "Compartment OCID where networking and compute resources are created."
  type        = string

  validation {
    condition     = can(regex("^ocid1\\.compartment\\..+", var.compartment_ocid))
    error_message = "compartment_ocid must be a valid OCI compartment OCID."
  }
}

variable "region" {
  description = "OCI region for deployment. This project is intentionally locked to the tenancy home region for Always Free safety."
  type        = string
  default     = "eu-frankfurt-1"

  validation {
    condition     = var.region == "eu-frankfurt-1"
    error_message = "This project is restricted to eu-frankfurt-1 to avoid non-free-region deployments."
  }
}

variable "oci_profile" {
  description = "OCI CLI config profile name in %USERPROFILE%/.oci/config."
  type        = string
  default     = "DEFAULT"
}

variable "name_prefix" {
  description = "Prefix applied to OCI resource display names."
  type        = string
  default     = "oci-a1-retry"

  validation {
    condition     = can(regex("^[a-zA-Z0-9-]{3,30}$", var.name_prefix))
    error_message = "name_prefix must be 3-30 characters and contain only letters, numbers, or hyphens."
  }
}

variable "availability_domain" {
  description = "Availability Domain name used for the compute instance. Set by scripts/apply-retry.ps1."
  type        = string

  validation {
    condition     = length(trim(var.availability_domain)) > 0
    error_message = "availability_domain cannot be empty."
  }
}

variable "shape" {
  description = "OCI compute shape. Kept strict for Always Free ARM policy."
  type        = string
  default     = "VM.Standard.A1.Flex"

  validation {
    condition     = var.shape == "VM.Standard.A1.Flex"
    error_message = "shape must be VM.Standard.A1.Flex in this project."
  }
}

variable "ocpus" {
  description = "Number of OCPUs for the A1 instance."
  type        = number
  default     = 1

  validation {
    condition     = var.ocpus >= 1 && var.ocpus <= 4 && floor(var.ocpus) == var.ocpus
    error_message = "ocpus must be an integer between 1 and 4."
  }
}

variable "memory_in_gbs" {
  description = "Memory in GB for the A1 instance."
  type        = number
  default     = 6

  validation {
    condition     = var.memory_in_gbs >= 1 && var.memory_in_gbs <= 24 && floor(var.memory_in_gbs) == var.memory_in_gbs
    error_message = "memory_in_gbs must be an integer between 1 and 24."
  }
}

variable "vcn_cidr" {
  description = "CIDR block for the VCN."
  type        = string
  default     = "10.0.0.0/16"

  validation {
    condition     = can(cidrnetmask(var.vcn_cidr))
    error_message = "vcn_cidr must be a valid IPv4 CIDR."
  }
}

variable "subnet_cidr" {
  description = "CIDR block for the regional subnet."
  type        = string
  default     = "10.0.1.0/24"

  validation {
    condition     = can(cidrnetmask(var.subnet_cidr))
    error_message = "subnet_cidr must be a valid IPv4 CIDR."
  }
}

variable "allowed_ssh_cidr" {
  description = "IPv4 CIDR allowed to connect over SSH. Scripts default this to detected public IP/32."
  type        = string
  default     = "0.0.0.0/0"

  validation {
    condition     = can(cidrnetmask(var.allowed_ssh_cidr))
    error_message = "allowed_ssh_cidr must be a valid IPv4 CIDR."
  }
}

variable "ssh_public_key" {
  description = "Public SSH key content (starts with ssh-)."
  type        = string

  validation {
    condition     = can(regex("^ssh-", trim(var.ssh_public_key)))
    error_message = "ssh_public_key must start with ssh-."
  }
}

variable "ssh_private_key_path_hint" {
  description = "Optional local private key path used to generate the SSH command output."
  type        = string
  default     = ""
}

variable "image_ocid_override" {
  description = "Optional image OCID override for deterministic image pinning."
  type        = string
  default     = null

  validation {
    condition     = var.image_ocid_override == null || can(regex("^ocid1\\.image\\..+", var.image_ocid_override))
    error_message = "image_ocid_override must be null or a valid image OCID."
  }
}

variable "image_operating_system" {
  description = "Operating system filter used when selecting the latest image."
  type        = string
  default     = "Canonical Ubuntu"
}

variable "image_operating_system_version" {
  description = "Operating system version filter used when selecting the latest image."
  type        = string
  default     = "24.04"
}

variable "assign_public_ip" {
  description = "Whether to assign a public IPv4 address to the primary VNIC."
  type        = bool
  default     = true
}

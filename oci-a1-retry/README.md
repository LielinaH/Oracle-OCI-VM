# OCI A1 Retry (Always Free) - Terraform + PowerShell

Provision one OCI Always Free ARM instance (`VM.Standard.A1.Flex`) with Ubuntu 24.04 and automatic retry across Availability Domains when OCI reports host/shape capacity exhaustion.

This project is intentionally strict for safety:
- Region policy locked to `eu-frankfurt-1` (Germany Central, Frankfurt).
- Shape policy locked to `VM.Standard.A1.Flex`.
- Image policy locked to Ubuntu 24.04 unless you explicitly set `image_ocid_override`.

## Prerequisites
- Windows with PowerShell 7+ (`pwsh`).
- Terraform CLI (`>= 1.6`).
- OCI CLI (`oci`) configured with API-key auth.
- Existing SSH keypair (public key file required by apply script).

## OCI API Key Auth Setup (High-Level)
1. In OCI Console, create an API key for your user and upload the public key.
2. Store the private API key locally (for example `%USERPROFILE%\.oci\oci_api_key.pem`).
3. Configure `%USERPROFILE%\.oci\config` with a profile (default: `DEFAULT`) containing:
- `user`
- `fingerprint`
- `tenancy`
- `region`
- `key_file`
4. Validate from terminal:
```powershell
oci -v
oci os ns get --profile DEFAULT --region eu-frankfurt-1
```

## Operator Input Map
- OCI API auth profile:
  `%USERPROFILE%\.oci\config` -> use via `-Profile` (default `DEFAULT`)
- Tenancy OCID:
  pass to scripts as `-TenancyOcid`
- Compartment OCID:
  pass to apply script as `-CompartmentOcid`
- SSH public key path:
  pass to apply script as `-SshPublicKeyPath` (example `%USERPROFILE%\.ssh\id_ed25519.pub`)
- SSH key passphrase:
  handled by your local SSH client/agent at connect time; never stored in this repo
- SSH ingress CIDR:
  optional `-AllowedSshCidr`; otherwise scripts auto-detect your public IP and use `/32`

## Quick Start
Run commands from `oci-a1-retry/`.

### 1) Preflight
```powershell
pwsh ./scripts/doctor.ps1 `
  -TenancyOcid "ocid1.tenancy.oc1..exampleuniqueID" `
  -Region "eu-frankfurt-1" `
  -Profile "DEFAULT"
```

### 2) Apply with AD Retry
```powershell
pwsh ./scripts/apply-retry.ps1 `
  -TenancyOcid "ocid1.tenancy.oc1..exampleuniqueID" `
  -CompartmentOcid "ocid1.compartment.oc1..exampleuniqueID" `
  -Region "eu-frankfurt-1" `
  -Profile "DEFAULT" `
  -NamePrefix "oci-a1-retry" `
  -SshPublicKeyPath "$env:USERPROFILE\.ssh\id_ed25519.pub"
```

Optional override:
```powershell
-AllowedSshCidr "203.0.113.10/32"
```

### 3) SSH
The apply script prints `ssh_command_powershell` output. Typical form:
```powershell
ssh -i "$env:USERPROFILE\.ssh\id_ed25519" ubuntu@<public_ip>
```

### 4) Destroy
```powershell
pwsh ./scripts/destroy.ps1 -Region "eu-frankfurt-1" -Profile "DEFAULT" -AutoApprove $true
```

## Optional Image Pinning
If latest Ubuntu 24.04 selection fails or you want deterministic rebuilds, set `image_ocid_override` in `terraform.auto.tfvars` or pass via Terraform CLI when applying manually.

## Troubleshooting

### "Out of capacity for shape" / "Out of host capacity"
- `apply-retry.ps1` detects these errors and retries automatically across all discovered ADs.
- AD names are discovered via OCI CLI, de-duplicated, and randomized each run.
- If every AD returns capacity errors, the script exits with a clear failure.

### No public IP or SSH not reachable
- Confirm subnet route table has `0.0.0.0/0 -> Internet Gateway`.
- Confirm security list allows TCP/22 from your effective `allowed_ssh_cidr`.
- Confirm `assign_public_ip=true` in Terraform variables.
- Wait a bit longer and retry SSH check (cloud-init may still be initializing).

### Image selection issues
- By default, Terraform queries the latest Ubuntu 24.04 image compatible with `VM.Standard.A1.Flex`.
- If no image is returned in your compartment context, set `image_ocid_override` to a known valid image OCID.

### Region guard fails
- This project intentionally enforces `eu-frankfurt-1` and checks tenancy home region for Always Free safety.

## State and Safety Notes
- Local Terraform state is used by default.
- For team/shared usage, migrate to a remote backend before collaborative operations.
- This repo never stores OCI private API keys or SSH private keys.
- Generated `terraform.auto.tfvars`, `.terraform/`, and state files are git-ignored.

## Expected Indicators
- `[PASS] Terraform and OCI CLI detected`
- `[PASS] OCI auth namespace check succeeded`
- `[PASS] Home region check passed for eu-frankfurt-1`
- `[PASS] AD discovery returned at least one AD`
- `[PASS] terraform fmt -check and validate succeeded`
- `[PASS] Apply succeeded in one AD after retry logic`
- `[PASS] Outputs include OCID, AD, public/private IP, SSH command`
- `[PASS] SSH port 22 reachable` (or a warning with guidance)
- `[PASS] Destroy completed`

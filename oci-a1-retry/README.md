# OCI A1 Retry (Always Free) - Terraform + PowerShell

Provision one OCI instance on `VM.Standard.A1.Flex` using Ubuntu 24.04, with automatic retry across Availability Domains when OCI returns host/shape capacity errors.

## Prerequisites
- Windows with PowerShell 7+ (`pwsh`)
- Terraform CLI (`>= 1.6`)
- OCI CLI (`oci`) configured with API-key auth
- Existing SSH key pair (public key path required)

## OCI API Key Auth Setup (High-Level)
1. In OCI Console, create an API key for your user and upload the public key.
2. Store the private API key locally (for example `%USERPROFILE%\.oci\oci_api_key.pem`).
3. Configure `%USERPROFILE%\.oci\config` with a profile (default `DEFAULT`) containing:
- `user`
- `fingerprint`
- `tenancy`
- `region`
- `key_file`
4. Validate auth:
```powershell
oci -v
oci os ns get --profile DEFAULT --region eu-frankfurt-1
```

## Operator Input Map
- OCI API auth profile:
  `%USERPROFILE%\.oci\config` via `-Profile` (default `DEFAULT`)
- Tenancy OCID:
  `-TenancyOcid`
- Compartment OCID:
  `-CompartmentOcid`
- SSH public key path:
  `-SshPublicKeyPath` (for example `%USERPROFILE%\.ssh\id_ed25519.pub`)
- SSH passphrase:
  handled by your local SSH client/agent; never stored in repo
- SSH ingress CIDR:
  optional `-AllowedSshCidr`; otherwise auto-detected via ipify and `/32`

## Progress Indicators
All scripts use:
- `Write-Progress` live progress bar
- a step-board table after each step with: `Index | Name | Status | Details`

Step statuses:
- `PENDING`: not started yet
- `RUNNING`: current step
- `PASS`: completed successfully
- `WARN`: completed with warning, execution continues
- `FAIL`: failed; final exit code is non-zero
- `SKIP`: not run because a prior requirement failed

## Region Policy
- Default region remains `eu-frankfurt-1`.
- Home-region discovery is **not** used by these scripts.
- Without `-EnforceRegion`:
- `eu-frankfurt-1` => `PASS`
- any other region => `WARN` and continue
- With `-EnforceRegion <region>`:
- mismatch => `FAIL`
- match => `PASS`

## Quick Start
Run from the `oci-a1-retry` project root.

### 1) Doctor / Preflight
```powershell
pwsh .\scripts\doctor.ps1 `
  -TenancyOcid "ocid1.tenancy.oc1..exampleuniqueID" `
  -Region "eu-frankfurt-1" `
  -Profile "DEFAULT"
```

Optional strict region enforcement:
```powershell
-EnforceRegion "eu-frankfurt-1"
-OciCliPath "C:\Program Files (x86)\Oracle\oci_cli\oci.exe"
-TerraformPath "$env:LOCALAPPDATA\Microsoft\WinGet\Links\terraform.exe"
```

### 2) Apply With AD Retry
```powershell
pwsh .\scripts\apply-retry.ps1 `
  -TenancyOcid "ocid1.tenancy.oc1..exampleuniqueID" `
  -CompartmentOcid "ocid1.compartment.oc1..exampleuniqueID" `
  -Region "eu-frankfurt-1" `
  -Profile "DEFAULT" `
  -NamePrefix "oci-a1-retry" `
  -SshPublicKeyPath "$env:USERPROFILE\.ssh\id_ed25519.pub"
```

Optional flags:
```powershell
-AllowedSshCidr "203.0.113.10/32"
-EnforceRegion "eu-frankfurt-1"
-Deterministic
-OciCliPath "C:\Program Files (x86)\Oracle\oci_cli\oci.exe"
-TerraformPath "$env:LOCALAPPDATA\Microsoft\WinGet\Links\terraform.exe"
-PromptOciPrivateKeyPassword
# less preferred: -OciPrivateKeyPassword "<passphrase>"
-Ocpus 1
-MemoryInGbs 6
```

### 3) SSH
Use the printed `ssh_command_powershell` output, for example:
```powershell
ssh -i "$env:USERPROFILE\.ssh\id_ed25519" ubuntu@<public_ip>
```

### 4) Destroy
```powershell
pwsh .\scripts\destroy.ps1 -Region "eu-frankfurt-1" -Profile "DEFAULT" -AutoApprove $true
```

## Image Selection
- Terraform selects image data with:
- `operating_system = "Canonical Ubuntu"`
- `operating_system_version = "24.04"`
- `shape = var.shape` (`VM.Standard.A1.Flex`) for compatibility gating
- If no match is found and no override is set, Terraform fails with:
  `Set image_ocid_override to a known-good ARM Ubuntu 24.04 image OCID for this region.`

## Troubleshooting

### "Out of capacity for shape" / "Out of host capacity"
- Apply retries across discovered ADs.
- With default behavior, AD order is randomized each run.
- Use `-Deterministic` for stable sorted AD order.

### Region mismatch behavior
- By default, non-`eu-frankfurt-1` regions produce `WARN` and continue.
- With `-EnforceRegion`, mismatch produces `FAIL`.

### OCI CLI command resolution issues
- If you see `Get-Acl`/module-load errors while running `oci` from script, force the executable:
  `-OciCliPath "C:\Program Files (x86)\Oracle\oci_cli\oci.exe"`
- The scripts also set `OCI_CLI_SUPPRESS_FILE_PERMISSIONS_WARNING=True` during execution to avoid Windows ACL-check failures.

### Terraform command resolution issues
- If `terraform` is installed but scripts say it is missing, set:
  `-TerraformPath "$env:LOCALAPPDATA\Microsoft\WinGet\Links\terraform.exe"`

### No public IP / SSH not reachable
- Verify route table has `0.0.0.0/0 -> Internet Gateway`.
- Verify security list allows TCP/22 from effective `allowed_ssh_cidr`.
- Verify `assign_public_ip=true`.

### Image selection issues
- Set `image_ocid_override` to a known-good Ubuntu 24.04 ARM image OCID for your region.

## State and Safety Notes
- Local Terraform state is used by default.
- `.terraform/`, state files, and `terraform.auto.tfvars` are git-ignored.
- Never store OCI private API keys or SSH private keys in repo.

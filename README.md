# Oracle OCI VM

Operator-friendly Terraform and PowerShell workflows for provisioning Oracle Cloud Infrastructure VM instances from Windows, with an emphasis on safe retries for `VM.Standard.A1.Flex` capacity failures.

## Included Project
- `oci-a1-retry/`: provisions a single OCI VM with preflight checks, availability-domain retry logic, duplicate-prevention guards, SSH reachability checks, and run reports.

## Highlights
- Retries across OCI availability domains when A1 capacity is unavailable.
- Uses explicit safety gates for root-compartment usage, paid shapes, duplicate VCN names, and parallel apply loops.
- Keeps local state, generated tfvars, logs, reports, and lock files out of git.
- Ships Windows-native PowerShell operator scripts instead of relying on ad hoc shell commands.

## Repository Layout
```text
.
|-- oci-a1-retry/
|   |-- compute.tf
|   |-- network.tf
|   |-- outputs.tf
|   |-- provider.tf
|   |-- variables.tf
|   |-- versions.tf
|   `-- scripts/
|       |-- _common.ps1
|       |-- apply-retry.ps1
|       |-- destroy.ps1
|       |-- doctor.ps1
|       `-- run-loop.ps1
|-- CONTRIBUTING.md
`-- README.md
```

## Quick Start
1. `Set-Location .\oci-a1-retry`
2. Run preflight checks with `pwsh .\scripts\doctor.ps1 -TenancyOcid "<tenancy_ocid>" -Region "eu-frankfurt-1" -Profile "DEFAULT"`
3. Deploy with `pwsh .\scripts\apply-retry.ps1 -TenancyOcid "<tenancy_ocid>" -CompartmentOcid "<compartment_ocid>" -SshPublicKeyPath "$env:USERPROFILE\.ssh\id_ed25519.pub"`
4. Tear down only with explicit approval: `pwsh .\scripts\destroy.ps1 -Region "eu-frankfurt-1" -Profile "DEFAULT" -AutoApprove`

Project-specific operator guidance lives in [oci-a1-retry/README.md](./oci-a1-retry/README.md). Contribution and validation standards live in [CONTRIBUTING.md](./CONTRIBUTING.md).

## Security / Cost Safety
- OCI API keys and SSH private keys are not stored in the repo.
- Local Terraform state and generated tfvars are ignored by git.
- Paid shapes require an explicit override before the scripts will proceed.
- Use a child compartment for test runs instead of the root tenancy compartment.

## Publishing Notes
- Keep OCI API keys, SSH private keys, `terraform.tfstate`, and real `terraform.auto.tfvars` out of version control.
- The repo is configured to ignore local runtime artifacts such as apply reports, retry logs, and Terraform working directories.
- If large logs were committed earlier in local history, remove or squash those commits before publishing a public history.

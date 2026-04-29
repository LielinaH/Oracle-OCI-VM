# Contributing

## Project Structure
- `oci-a1-retry/` contains the publishable Terraform configuration and PowerShell operator scripts.
- Terraform files live at the project root: `versions.tf`, `provider.tf`, `variables.tf`, `network.tf`, `compute.tf`, and `outputs.tf`.
- Shared PowerShell helpers live in `oci-a1-retry/scripts/_common.ps1`.
- Workflow entrypoints live in `oci-a1-retry/scripts/doctor.ps1`, `apply-retry.ps1`, `destroy.ps1`, and `run-loop.ps1`.

## Development Standards
- Use 4-space indentation in Terraform and PowerShell.
- Keep PowerShell functions in `Verb-Noun` form with explicit parameters and strict mode enabled.
- Prefer shared utilities in `_common.ps1` over duplicating path resolution or step-board logic.
- Keep Terraform resource and variable names in `snake_case`.

## Validation
Run commands from `oci-a1-retry/`.

- `terraform fmt -recursive`
- `terraform validate`
- `pwsh .\scripts\doctor.ps1 -TenancyOcid "<ocid>" -Region "eu-frankfurt-1" -Profile "DEFAULT"`

For behavior changes, also run one controlled `apply-retry.ps1` execution in a non-production compartment and capture the resulting report path.

## Commit Guidance
- Prefer concise imperative subjects with a scope prefix such as `feat:` or `refactor:`.
- Include the operator impact in the commit or pull request description: region, compartment scope, and whether `allow_paid_shape` was involved.
- Include validation evidence for Terraform and PowerShell changes.

## Security Rules
- Never commit OCI private API keys, SSH private keys, `.tfstate`, or real `.tfvars` files.
- Use `terraform.tfvars.example` as the example source for local values.
- Keep `allow_paid_shape = false` unless you intentionally validate billable shapes.

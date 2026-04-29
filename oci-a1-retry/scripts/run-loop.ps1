[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$TenancyOcid,

    [Parameter(Mandatory = $true)]
    [string]$CompartmentOcid,

    [Parameter(Mandatory = $true)]
    [string]$SshPublicKeyPath,

    [string]$Region = "eu-frankfurt-1",
    [string]$Profile = "DEFAULT",
    [string]$NamePrefix = "oci-a1-retry",
    [string]$AllowedSshCidr,
    [string]$EnforceRegion,
    [switch]$Deterministic,
    [string]$OciCliPath,
    [string]$TerraformPath,
    [switch]$AllowRootCompartment,
    [switch]$AllowExistingNamedResources,
    [switch]$ForceTakeLock,
    [string]$OciPrivateKeyPassword,
    [switch]$PromptOciPrivateKeyPassword,
    [string]$Shape = "VM.Standard.A1.Flex",
    [switch]$AllowPaidShape,
    [int]$Ocpus = 1,
    [int]$MemoryInGbs = 6,
    [string]$ImageOperatingSystem = "Canonical Ubuntu",
    [string]$ImageOperatingSystemVersion = "24.04",
    [int]$MinDelaySeconds = 45,
    [int]$MaxDelaySeconds = 180,
    [int]$MaxRounds = 0
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

if ($MinDelaySeconds -lt 1) { throw "MinDelaySeconds must be >= 1." }
if ($MaxDelaySeconds -lt $MinDelaySeconds) { throw "MaxDelaySeconds must be >= MinDelaySeconds." }
if ($MaxRounds -lt 0) { throw "MaxRounds must be >= 0." }

$projectRoot = Split-Path -Parent $PSScriptRoot
Push-Location $projectRoot
try {
    $round = 0
    while ($true) {
        $round++
        $startedUtc = [DateTime]::UtcNow.ToString("u")
        Write-Host "[$startedUtc] Round $round started." -ForegroundColor Cyan

        $applyArgs = @(
            ".\scripts\apply-retry.ps1",
            "-TenancyOcid", $TenancyOcid,
            "-CompartmentOcid", $CompartmentOcid,
            "-Region", $Region,
            "-Profile", $Profile,
            "-NamePrefix", $NamePrefix,
            "-SshPublicKeyPath", $SshPublicKeyPath,
            "-Shape", $Shape,
            "-Ocpus", $Ocpus,
            "-MemoryInGbs", $MemoryInGbs,
            "-ImageOperatingSystem", $ImageOperatingSystem,
            "-ImageOperatingSystemVersion", $ImageOperatingSystemVersion
        )

        if (-not [string]::IsNullOrWhiteSpace($AllowedSshCidr)) {
            $applyArgs += @("-AllowedSshCidr", $AllowedSshCidr)
        }
        if (-not [string]::IsNullOrWhiteSpace($EnforceRegion)) {
            $applyArgs += @("-EnforceRegion", $EnforceRegion)
        }
        if (-not [string]::IsNullOrWhiteSpace($OciCliPath)) {
            $applyArgs += @("-OciCliPath", $OciCliPath)
        }
        if (-not [string]::IsNullOrWhiteSpace($TerraformPath)) {
            $applyArgs += @("-TerraformPath", $TerraformPath)
        }
        if (-not [string]::IsNullOrWhiteSpace($OciPrivateKeyPassword)) {
            $applyArgs += @("-OciPrivateKeyPassword", $OciPrivateKeyPassword)
        }
        if ($Deterministic) {
            $applyArgs += "-Deterministic"
        }
        if ($AllowRootCompartment) {
            $applyArgs += "-AllowRootCompartment"
        }
        if ($AllowExistingNamedResources) {
            $applyArgs += "-AllowExistingNamedResources"
        }
        if ($ForceTakeLock) {
            $applyArgs += "-ForceTakeLock"
        }
        if ($PromptOciPrivateKeyPassword) {
            $applyArgs += "-PromptOciPrivateKeyPassword"
        }
        if ($AllowPaidShape) {
            $applyArgs += "-AllowPaidShape"
        }

        & pwsh @applyArgs

        $exitCode = $LASTEXITCODE
        if ($exitCode -eq 0) {
            $endedUtc = [DateTime]::UtcNow.ToString("u")
            Write-Host "[$endedUtc] Success on round $round." -ForegroundColor Green
            exit 0
        }

        if ($MaxRounds -gt 0 -and $round -ge $MaxRounds) {
            $endedUtc = [DateTime]::UtcNow.ToString("u")
            Write-Host "[$endedUtc] Reached MaxRounds=$MaxRounds. Last exit code: $exitCode" -ForegroundColor Yellow
            exit $exitCode
        }

        $delay = Get-Random -Minimum $MinDelaySeconds -Maximum ($MaxDelaySeconds + 1)
        $nextUtc = [DateTime]::UtcNow.AddSeconds($delay).ToString("u")
        Write-Host "Round $round failed (exit $exitCode). Sleeping $delay seconds. Next round at $nextUtc" -ForegroundColor Yellow
        Start-Sleep -Seconds $delay
    }
}
finally {
    Pop-Location
}

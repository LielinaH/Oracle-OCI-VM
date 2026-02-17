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

        & pwsh .\scripts\apply-retry.ps1 `
            -TenancyOcid $TenancyOcid `
            -CompartmentOcid $CompartmentOcid `
            -Region $Region `
            -Profile $Profile `
            -NamePrefix $NamePrefix `
            -SshPublicKeyPath $SshPublicKeyPath

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

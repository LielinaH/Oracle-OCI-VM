#Requires -Version 7.0
[CmdletBinding()]
param(
    [string]$Region = "eu-frankfurt-1",
    [string]$Profile = "DEFAULT",
    [bool]$AutoApprove = $true
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
. "$PSScriptRoot\_common.ps1"

function Write-Indicator {
    param(
        [ValidateSet("PASS", "FAIL", "WARN", "INFO")]
        [string]$Level,
        [string]$Message
    )

    switch ($Level) {
        "PASS" { Write-Host "[PASS] $Message" -ForegroundColor Green }
        "FAIL" { Write-Host "[FAIL] $Message" -ForegroundColor Red }
        "WARN" { Write-Host "[WARN] $Message" -ForegroundColor Yellow }
        "INFO" { Write-Host "[INFO] $Message" -ForegroundColor Cyan }
    }
}

function Invoke-ExternalCapture {
    param(
        [Parameter(Mandatory = $true)]
        [string]$File,
        [Parameter(Mandatory = $true)]
        [string[]]$Arguments
    )

    $lines = & $File @Arguments 2>&1
    $exitCode = $LASTEXITCODE
    $text = ($lines | ForEach-Object { $_.ToString() }) -join [Environment]::NewLine
    return [pscustomobject]@{
        ExitCode = $exitCode
        Output   = $text
    }
}

$projectRoot = Split-Path -Parent $PSScriptRoot
Push-Location $projectRoot
try {
    Write-Indicator -Level "INFO" -Message "Starting terraform destroy from $projectRoot"

    if (-not (Get-Command terraform -ErrorAction SilentlyContinue)) {
        throw "Terraform is not installed or not on PATH."
    }

    $initResult = Invoke-ExternalCapture -File "terraform" -Arguments @("init", "-input=false", "-no-color")
    if ($initResult.ExitCode -ne 0) {
        throw "terraform init failed. Output:`n$($initResult.Output)"
    }
    Write-Indicator -Level "PASS" -Message "terraform init succeeded."

    $destroyArgs = @(
        "destroy",
        "-input=false",
        "-no-color",
        "-var", "region=$Region",
        "-var", "oci_profile=$Profile"
    )
    if ($AutoApprove) {
        $destroyArgs += "-auto-approve"
    }

    $destroyResult = Invoke-ExternalCapture -File "terraform" -Arguments $destroyArgs
    if ($destroyResult.ExitCode -ne 0) {
        throw "terraform destroy failed. Output:`n$($destroyResult.Output)"
    }

    Write-Indicator -Level "PASS" -Message "Destroy completed."
    exit 0
}
catch {
    Write-Indicator -Level "FAIL" -Message $_.Exception.Message
    exit 1
}
finally {
    Pop-Location
}

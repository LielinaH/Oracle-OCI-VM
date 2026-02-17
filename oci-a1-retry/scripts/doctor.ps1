#Requires -Version 7.0
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$TenancyOcid,

    [string]$Region = "eu-frankfurt-1",
    [string]$Profile = "DEFAULT",
    [string]$AllowedSshCidr
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
. "$PSScriptRoot\_common.ps1"

$script:FailureCount = 0

function Write-Indicator {
    param(
        [ValidateSet("PASS", "FAIL", "WARN", "INFO")]
        [string]$Level,
        [string]$Message
    )

    switch ($Level) {
        "PASS" { Write-Host "[PASS] $Message" -ForegroundColor Green }
        "FAIL" { Write-Host "[FAIL] $Message" -ForegroundColor Red; $script:FailureCount++ }
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

function Convert-OciRawList {
    param(
        [string]$RawText
    )

    $trimmed = $RawText.Trim()
    if ([string]::IsNullOrWhiteSpace($trimmed)) {
        return @()
    }

    if ($trimmed.StartsWith("[")) {
        try {
            $json = $trimmed | ConvertFrom-Json
            return @($json | ForEach-Object { $_.ToString().Trim() } | Where-Object { $_ -ne "" })
        }
        catch {
            # Fall back to line parsing.
        }
    }

    $items = @($trimmed -split "\r?\n" | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne "" })
    if ($items.Count -eq 1 -and $items[0] -match "\s+") {
        $items = @($items[0] -split "\s+" | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne "" })
    }
    return $items
}

function Get-HomeRegion {
    param(
        [string]$TenancyId,
        [string]$RequestedRegion,
        [string]$CliProfile
    )

    $query = 'data[?"is-home-region"]."region-name" | [0]'
    $result = Invoke-ExternalCapture -File "oci" -Arguments @(
        "iam", "region-subscription", "list",
        "--tenancy-id", $TenancyId,
        "--profile", $CliProfile,
        "--region", $RequestedRegion,
        "--query", $query,
        "--raw-output",
        "--all"
    )

    if ($result.ExitCode -ne 0) {
        Write-Indicator -Level "FAIL" -Message "Failed to query tenancy home region. OCI output: $($result.Output)"
        return $null
    }

    $homeRegion = $result.Output.Trim()
    if ([string]::IsNullOrWhiteSpace($homeRegion) -or $homeRegion -eq "null") {
        Write-Indicator -Level "FAIL" -Message "Home region lookup returned empty output."
        return $null
    }

    return $homeRegion
}

function Get-DetectedPublicIp {
    try {
        $ip = (Invoke-RestMethod -Uri "https://api.ipify.org" -TimeoutSec 10).ToString().Trim()
        if ($ip -match "^\d{1,3}(\.\d{1,3}){3}$") {
            return $ip
        }
    }
    catch {
        return $null
    }
    return $null
}

function Test-Ipv4Cidr {
    param(
        [string]$Value
    )

    if ($Value -notmatch "^(\d{1,3}\.){3}\d{1,3}/([0-9]|[1-2][0-9]|3[0-2])$") {
        return $false
    }

    $parts = $Value.Split("/")
    $octets = $parts[0].Split(".")
    foreach ($octet in $octets) {
        $intValue = [int]$octet
        if ($intValue -lt 0 -or $intValue -gt 255) {
            return $false
        }
    }
    return $true
}

$projectRoot = Split-Path -Parent $PSScriptRoot
Push-Location $projectRoot
try {
    Write-Indicator -Level "INFO" -Message "Running preflight checks in $projectRoot"
    Write-Indicator -Level "INFO" -Message "Using OCI profile '$Profile' from $HOME/.oci/config"

    $terraformCmd = Get-Command terraform -ErrorAction SilentlyContinue
    if (-not $terraformCmd) {
        Write-Indicator -Level "FAIL" -Message "Terraform is not installed or not on PATH."
    }
    else {
        $tfVersion = Invoke-ExternalCapture -File "terraform" -Arguments @("version")
        if ($tfVersion.ExitCode -eq 0) {
            $firstLine = ($tfVersion.Output -split "\r?\n")[0]
            Write-Indicator -Level "PASS" -Message "Terraform detected: $firstLine"
        }
        else {
            Write-Indicator -Level "FAIL" -Message "Terraform version check failed. Output: $($tfVersion.Output)"
        }
    }

    $ociCmd = Get-Command oci -ErrorAction SilentlyContinue
    if (-not $ociCmd) {
        Write-Indicator -Level "FAIL" -Message "OCI CLI is not installed or not on PATH."
    }
    else {
        $ociVersion = Invoke-ExternalCapture -File "oci" -Arguments @("-v")
        if ($ociVersion.ExitCode -eq 0) {
            Write-Indicator -Level "PASS" -Message "OCI CLI detected: $($ociVersion.Output.Trim())"
        }
        else {
            Write-Indicator -Level "FAIL" -Message "OCI CLI version check failed. Output: $($ociVersion.Output)"
        }
    }

    if ($ociCmd) {
        $ns = Invoke-ExternalCapture -File "oci" -Arguments @(
            "os", "ns", "get",
            "--profile", $Profile,
            "--region", $Region,
            "--query", "data",
            "--raw-output"
        )
        if ($ns.ExitCode -eq 0) {
            Write-Indicator -Level "PASS" -Message "OCI auth verified via object storage namespace: $($ns.Output.Trim())"
        }
        else {
            Write-Indicator -Level "FAIL" -Message "OCI auth failed. Check %USERPROFILE%\\.oci\\config profile '$Profile'. OCI output: $($ns.Output)"
        }

        $homeRegion = Get-HomeRegion -TenancyId $TenancyOcid -RequestedRegion $Region -CliProfile $Profile
        if ($homeRegion) {
            if ($homeRegion -ne $Region) {
                Write-Indicator -Level "FAIL" -Message "Requested region '$Region' is not tenancy home region '$homeRegion'."
            }
            else {
                Write-Indicator -Level "PASS" -Message "Home region check passed: $homeRegion"
            }
            if ($Region -ne "eu-frankfurt-1") {
                Write-Indicator -Level "FAIL" -Message "Project policy requires eu-frankfurt-1 for Always Free guardrails."
            }
        }

        $adResult = Invoke-ExternalCapture -File "oci" -Arguments @(
            "iam", "availability-domain", "list",
            "--compartment-id", $TenancyOcid,
            "--profile", $Profile,
            "--region", $Region,
            "--query", "data[].name",
            "--raw-output",
            "--all"
        )
        if ($adResult.ExitCode -ne 0) {
            Write-Indicator -Level "FAIL" -Message "Failed to list availability domains. OCI output: $($adResult.Output)"
        }
        else {
            $ads = @(Convert-OciRawList -RawText $adResult.Output | Sort-Object -Unique)
            if ($ads.Count -gt 0) {
                Write-Indicator -Level "PASS" -Message "AD discovery succeeded: $($ads -join ', ')"
            }
            else {
                Write-Indicator -Level "FAIL" -Message "AD discovery returned zero results."
            }
        }
    }

    if ($terraformCmd) {
        $initResult = Invoke-ExternalCapture -File "terraform" -Arguments @("init", "-input=false", "-no-color")
        if ($initResult.ExitCode -eq 0) {
            Write-Indicator -Level "PASS" -Message "terraform init succeeded."
        }
        else {
            Write-Indicator -Level "FAIL" -Message "terraform init failed. Output: $($initResult.Output)"
        }

        $fmtResult = Invoke-ExternalCapture -File "terraform" -Arguments @("fmt", "-check", "-recursive")
        if ($fmtResult.ExitCode -eq 0) {
            Write-Indicator -Level "PASS" -Message "terraform fmt -check -recursive succeeded."
        }
        else {
            Write-Indicator -Level "FAIL" -Message "terraform fmt -check failed. Output: $($fmtResult.Output)"
        }

        $validateResult = Invoke-ExternalCapture -File "terraform" -Arguments @("validate", "-no-color")
        if ($validateResult.ExitCode -eq 0) {
            Write-Indicator -Level "PASS" -Message "terraform validate succeeded."
        }
        else {
            Write-Indicator -Level "FAIL" -Message "terraform validate failed. Output: $($validateResult.Output)"
        }
    }

    $detectedIp = Get-DetectedPublicIp
    if ($AllowedSshCidr) {
        if (Test-Ipv4Cidr -Value $AllowedSshCidr) {
            Write-Indicator -Level "PASS" -Message "allowed_ssh_cidr override supplied: $AllowedSshCidr"
        }
        else {
            Write-Indicator -Level "FAIL" -Message "allowed_ssh_cidr override is not a valid IPv4 CIDR: $AllowedSshCidr"
        }
    }
    elseif ($detectedIp) {
        Write-Indicator -Level "PASS" -Message "Detected public IP: $detectedIp (effective allowed_ssh_cidr: $detectedIp/32)"
    }
    else {
        Write-Indicator -Level "WARN" -Message "Public IP detection failed. effective allowed_ssh_cidr will fall back to 0.0.0.0/0."
    }

    if ($script:FailureCount -gt 0) {
        Write-Indicator -Level "FAIL" -Message "Doctor checks failed: $script:FailureCount failure(s)."
        exit 1
    }

    Write-Indicator -Level "PASS" -Message "All doctor checks passed."
    exit 0
}
finally {
    Pop-Location
}

#Requires -Version 7.0
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$TenancyOcid,

    [Parameter(Mandatory = $true)]
    [string]$CompartmentOcid,

    [string]$Region = "eu-frankfurt-1",
    [string]$Profile = "DEFAULT",
    [string]$NamePrefix = "oci-a1-retry",

    [Parameter(Mandatory = $true)]
    [string]$SshPublicKeyPath,

    [string]$AllowedSshCidr,
    [int]$SshWaitTimeoutSeconds = 180
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

function Convert-ToTerraformStringLiteral {
    param(
        [string]$Value
    )

    $escaped = $Value.Replace("\", "\\").Replace('"', '\"').Replace("`r", "").Replace("`n", "\n")
    return '"' + $escaped + '"'
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
        throw "Unable to determine tenancy home region. OCI output: $($result.Output)"
    }

    $homeRegion = $result.Output.Trim()
    if ([string]::IsNullOrWhiteSpace($homeRegion) -or $homeRegion -eq "null") {
        throw "Home region lookup returned empty output."
    }
    return $homeRegion
}

function Get-AvailabilityDomains {
    param(
        [string]$TenancyId,
        [string]$RequestedRegion,
        [string]$CliProfile
    )

    $result = Invoke-ExternalCapture -File "oci" -Arguments @(
        "iam", "availability-domain", "list",
        "--compartment-id", $TenancyId,
        "--profile", $CliProfile,
        "--region", $RequestedRegion,
        "--query", "data[].name",
        "--raw-output",
        "--all"
    )
    if ($result.ExitCode -ne 0) {
        throw "Unable to list availability domains. OCI output: $($result.Output)"
    }

    $ads = @(Convert-OciRawList -RawText $result.Output | Sort-Object -Unique)
    if ($ads.Count -eq 0) {
        throw "OCI returned zero availability domains."
    }
    return $ads
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

function Get-TerraformOutputRaw {
    param(
        [string]$Name
    )

    $result = Invoke-ExternalCapture -File "terraform" -Arguments @("output", "-raw", $Name)
    if ($result.ExitCode -ne 0) {
        return ""
    }
    return $result.Output.Trim()
}

$projectRoot = Split-Path -Parent $PSScriptRoot
Push-Location $projectRoot
try {
    Write-Indicator -Level "INFO" -Message "Starting apply with AD retry from $projectRoot"
    Write-Indicator -Level "INFO" -Message "Using OCI profile '$Profile' from $HOME/.oci/config"
    Write-Indicator -Level "INFO" -Message "Using SSH public key file '$SshPublicKeyPath'"

    if (-not (Get-Command terraform -ErrorAction SilentlyContinue)) {
        throw "Terraform is not installed or not on PATH."
    }
    if (-not (Get-Command oci -ErrorAction SilentlyContinue)) {
        throw "OCI CLI is not installed or not on PATH."
    }

    if (-not (Test-Path -Path $SshPublicKeyPath -PathType Leaf)) {
        throw "SSH public key file not found: $SshPublicKeyPath"
    }

    $sshPublicKey = (Get-Content -Path $SshPublicKeyPath -Raw).Trim()
    if ($sshPublicKey -notmatch "^ssh-") {
        throw "SSH public key file must start with ssh-."
    }
    Write-Indicator -Level "PASS" -Message "SSH public key format looks valid."

    $privateKeyHint = if ($SshPublicKeyPath.EndsWith(".pub")) {
        $SshPublicKeyPath.Substring(0, $SshPublicKeyPath.Length - 4)
    }
    else {
        "<path-to-private-key>"
    }

    $effectiveAllowedSshCidr = $AllowedSshCidr
    if (-not $effectiveAllowedSshCidr) {
        $publicIp = Get-DetectedPublicIp
        if ($publicIp) {
            $effectiveAllowedSshCidr = "$publicIp/32"
            Write-Indicator -Level "PASS" -Message "Detected public IP $publicIp. Using allowed_ssh_cidr=$effectiveAllowedSshCidr"
        }
        else {
            $effectiveAllowedSshCidr = "0.0.0.0/0"
            Write-Indicator -Level "WARN" -Message "Could not detect public IP. Falling back to allowed_ssh_cidr=0.0.0.0/0"
        }
    }
    else {
        Write-Indicator -Level "INFO" -Message "Using caller-provided allowed_ssh_cidr=$effectiveAllowedSshCidr"
    }

    if (-not (Test-Ipv4Cidr -Value $effectiveAllowedSshCidr)) {
        throw "allowed_ssh_cidr is not a valid IPv4 CIDR: $effectiveAllowedSshCidr"
    }

    $homeRegion = Get-HomeRegion -TenancyId $TenancyOcid -RequestedRegion $Region -CliProfile $Profile
    if ($homeRegion -ne $Region) {
        throw "Requested region '$Region' is not tenancy home region '$homeRegion'."
    }
    if ($Region -ne "eu-frankfurt-1") {
        throw "Project policy requires region eu-frankfurt-1."
    }
    Write-Indicator -Level "PASS" -Message "Home region guard passed: $Region"

    $ads = @(Get-AvailabilityDomains -TenancyId $TenancyOcid -RequestedRegion $Region -CliProfile $Profile)
    $adsRandomized = @(Get-Random -InputObject $ads -Count $ads.Count)
    Write-Indicator -Level "INFO" -Message "AD candidates discovered: $($ads -join ', ')"
    Write-Indicator -Level "INFO" -Message "AD retry order this run: $($adsRandomized -join ', ')"

    $tfvarsPath = Join-Path $projectRoot "terraform.auto.tfvars"
    $tfvarsLines = @(
        "compartment_ocid = $(Convert-ToTerraformStringLiteral -Value $CompartmentOcid)",
        "region = $(Convert-ToTerraformStringLiteral -Value $Region)",
        "oci_profile = $(Convert-ToTerraformStringLiteral -Value $Profile)",
        "name_prefix = $(Convert-ToTerraformStringLiteral -Value $NamePrefix)",
        "ssh_public_key = $(Convert-ToTerraformStringLiteral -Value $sshPublicKey)",
        "allowed_ssh_cidr = $(Convert-ToTerraformStringLiteral -Value $effectiveAllowedSshCidr)",
        "ssh_private_key_path_hint = $(Convert-ToTerraformStringLiteral -Value $privateKeyHint)"
    )
    Set-Content -Path $tfvarsPath -Value ($tfvarsLines -join [Environment]::NewLine) -Encoding UTF8
    Write-Indicator -Level "PASS" -Message "Wrote terraform.auto.tfvars with runtime inputs."

    $initResult = Invoke-ExternalCapture -File "terraform" -Arguments @("init", "-input=false", "-no-color")
    if ($initResult.ExitCode -ne 0) {
        throw "terraform init failed. Output:`n$($initResult.Output)"
    }
    Write-Indicator -Level "PASS" -Message "terraform init succeeded."

    $successfulAd = $null
    foreach ($ad in $adsRandomized) {
        Write-Indicator -Level "INFO" -Message "Attempting terraform apply in AD '$ad'"
        $applyResult = Invoke-ExternalCapture -File "terraform" -Arguments @(
            "apply",
            "-auto-approve",
            "-input=false",
            "-no-color",
            "-var", "availability_domain=$ad"
        )

        if ($applyResult.ExitCode -eq 0) {
            $successfulAd = $ad
            Write-Indicator -Level "PASS" -Message "Apply succeeded in AD '$ad'."
            break
        }

        if ($applyResult.Output -match "(?i)Out of capacity for shape|Out of host capacity") {
            Write-Indicator -Level "WARN" -Message "Capacity error in AD '$ad'. Trying next AD."
            continue
        }

        throw "terraform apply failed with a non-capacity error in AD '$ad'. Output:`n$($applyResult.Output)"
    }

    if (-not $successfulAd) {
        throw "All AD retries were exhausted due to capacity errors."
    }

    $instanceOcid = Get-TerraformOutputRaw -Name "instance_ocid"
    $adUsed = Get-TerraformOutputRaw -Name "ad_used"
    $publicIp = Get-TerraformOutputRaw -Name "public_ip"
    $privateIp = Get-TerraformOutputRaw -Name "private_ip"
    $sshCommand = Get-TerraformOutputRaw -Name "ssh_command_powershell"

    Write-Host ""
    Write-Indicator -Level "PASS" -Message "Terraform outputs:"
    Write-Host "  instance_ocid          = $instanceOcid"
    Write-Host "  ad_used                = $adUsed"
    Write-Host "  public_ip              = $publicIp"
    Write-Host "  private_ip             = $privateIp"
    Write-Host "  ssh_command_powershell = $sshCommand"

    if (-not $publicIp) {
        Write-Indicator -Level "WARN" -Message "No public IP reported. Skipping SSH port reachability check."
        exit 0
    }

    if (-not (Get-Command Test-NetConnection -ErrorAction SilentlyContinue)) {
        Write-Indicator -Level "WARN" -Message "Test-NetConnection command not found. Skipping SSH port check."
        exit 0
    }

    $deadline = (Get-Date).AddSeconds($SshWaitTimeoutSeconds)
    $attempt = 0
    $reachable = $false
    while ((Get-Date) -lt $deadline) {
        $attempt++
        $tnc = Test-NetConnection -ComputerName $publicIp -Port 22 -WarningAction SilentlyContinue
        if ($tnc.TcpTestSucceeded) {
            $reachable = $true
            break
        }
        Write-Indicator -Level "INFO" -Message "SSH port 22 not reachable yet (attempt $attempt). Retrying in 10s."
        Start-Sleep -Seconds 10
    }

    if ($reachable) {
        Write-Indicator -Level "PASS" -Message "SSH reachability check passed for $publicIp:22"
    }
    else {
        Write-Indicator -Level "WARN" -Message "SSH reachability check timed out after $SshWaitTimeoutSeconds seconds."
    }

    exit 0
}
catch {
    Write-Indicator -Level "FAIL" -Message $_.Exception.Message
    exit 1
}
finally {
    Pop-Location
}

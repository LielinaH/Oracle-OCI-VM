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
    [int]$SshWaitTimeoutSeconds = 180,
    [string]$EnforceRegion,
    [switch]$Deterministic,
    [int]$Ocpus = 1,
    [int]$MemoryInGbs = 6
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
. "$PSScriptRoot\_common.ps1"

$TenancyOcid = $TenancyOcid.Trim()
$CompartmentOcid = $CompartmentOcid.Trim()
$Region = $Region.Trim()
$Profile = $Profile.Trim()
$NamePrefix = $NamePrefix.Trim()
$AllowedSshCidr = if ($AllowedSshCidr) { $AllowedSshCidr.Trim() } else { $null }
$EnforceRegion = if ($EnforceRegion) { $EnforceRegion.Trim() } else { $null }

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
            # Fall through to text parsing.
        }
    }

    $items = @($trimmed -split "[,\r\n]" | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne "" })
    return @(
        $items |
        Where-Object { $_ -notmatch "^Error while loading conda entry point" } |
        ForEach-Object { $_.Replace("[", "").Replace("]", "").Replace('"', "").Trim() } |
        Where-Object { $_ -ne "" }
    )
}

function Get-CleanOciLines {
    param(
        [string]$RawText
    )

    return @(
        $RawText -split "\r?\n" |
        ForEach-Object { $_.Trim() } |
        Where-Object { $_ -ne "" -and $_ -notmatch "^Error while loading conda entry point" }
    )
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

$steps = @(
    "Preflight: PowerShell 7+",
    "Validate inputs (TenancyOcid/CompartmentOcid/SshPublicKeyPath)",
    "Auth indicator: oci os ns get",
    "Discover ADs (dedupe; order randomized unless -Deterministic)",
    "Region policy check (default/warn; enforce option)",
    "Detect public IP (ipify) => allowed_ssh_cidr (WARN fallback 0.0.0.0/0)",
    "Write terraform.auto.tfvars (non-secret values only)",
    "terraform init + validate (init + fmt + validate) as indicators",
    "Attempt apply with AD retry loop (show remaining attempts each try)",
    "Outputs (OCID, AD used, public/private IP, SSH command)",
    "SSH reachability test (Test-NetConnection port 22 with retries)",
    "Summary indicators"
)

$activity = "apply-retry.ps1 progress"
$board = New-StepBoard -StepNames $steps
$projectRoot = Split-Path -Parent $PSScriptRoot
$exitCode = 1
$currentStep = 0
$summaryDone = $false

$ociAvailable = $false
$terraformAvailable = $false
$sshPublicKey = ""
$privateKeyHint = "<path-to-private-key>"
$effectiveAllowedSshCidr = ""
$inputsValid = $false
$adOrder = @()
$applySucceeded = $false
$adUsed = ""
$publicIp = ""
$privateIp = ""
$instanceOcid = ""
$sshCommand = ""

function Start-Step {
    param([int]$Index)
    Set-StepStatus -Board $board -Index $Index -Status "RUNNING" -Details ""
    Update-ProgressUi -Board $board -Activity $activity -CurrentIndex $Index -CurrentLabel $board[$Index - 1].Name
}

function End-Step {
    param(
        [int]$Index,
        [ValidateSet("PASS", "WARN", "FAIL", "SKIP")]
        [string]$Status,
        [string]$Details
    )
    Set-StepStatus -Board $board -Index $Index -Status $Status -Details $Details
    Show-StepBoard -Board $board -Title "apply-retry.ps1 step board"
}

Push-Location $projectRoot
try {
    $currentStep = 1
    Start-Step -Index $currentStep
    if ($PSVersionTable.PSVersion.Major -ge 7) {
        End-Step -Index $currentStep -Status "PASS" -Details "PowerShell $($PSVersionTable.PSVersion) detected."
    }
    else {
        End-Step -Index $currentStep -Status "FAIL" -Details "PowerShell 7+ required. Current: $($PSVersionTable.PSVersion)."
    }

    $currentStep = 2
    Start-Step -Index $currentStep
    $validationIssues = @()

    if (-not (Test-Path -Path $SshPublicKeyPath -PathType Leaf)) {
        $validationIssues += "SSH public key file not found: $SshPublicKeyPath"
    }
    else {
        $sshPublicKey = (Get-Content -Path $SshPublicKeyPath -Raw).Trim()
        if ($sshPublicKey -notmatch "^ssh-") {
            $validationIssues += "SSH public key must start with ssh-."
        }
        if ($SshPublicKeyPath.EndsWith(".pub")) {
            $privateKeyHint = $SshPublicKeyPath.Substring(0, $SshPublicKeyPath.Length - 4)
        }
    }

    if ($TenancyOcid -notmatch "^(?i)ocid1\\.tenancy\\..+") {
        $validationIssues += "TenancyOcid is not a valid tenancy OCID."
    }
    if ($CompartmentOcid -notmatch "^(?i)ocid1\\.(compartment|tenancy)\\..+") {
        $validationIssues += "CompartmentOcid must be a compartment/root-tenancy OCID."
    }

    $ociAvailable = (Get-Command oci -ErrorAction SilentlyContinue) -ne $null
    $terraformAvailable = (Get-Command terraform -ErrorAction SilentlyContinue) -ne $null
    if (-not $ociAvailable) { $validationIssues += "oci CLI not found on PATH." }
    if (-not $terraformAvailable) { $validationIssues += "terraform not found on PATH." }

    if ($validationIssues.Count -gt 0) {
        $inputsValid = $false
        End-Step -Index $currentStep -Status "FAIL" -Details ($validationIssues -join " ")
    }
    else {
        $inputsValid = $true
        End-Step -Index $currentStep -Status "PASS" -Details "Inputs validated. Profile=$Profile."
    }

    $currentStep = 3
    Start-Step -Index $currentStep
    if (-not $ociAvailable) {
        End-Step -Index $currentStep -Status "FAIL" -Details "Cannot run auth indicator because oci CLI is missing."
    }
    else {
        $nsResult = Invoke-ExternalCapture -File "oci" -Arguments @(
            "os", "ns", "get",
            "--profile", $Profile,
            "--region", $Region,
            "--query", "data",
            "--raw-output"
        )
        if ($nsResult.ExitCode -eq 0) {
            $cleanNs = @(Get-CleanOciLines -RawText $nsResult.Output)
            $nsValue = if ($cleanNs.Count -gt 0) { $cleanNs[$cleanNs.Count - 1] } else { $nsResult.Output.Trim() }
            End-Step -Index $currentStep -Status "PASS" -Details "Namespace: $nsValue"
        }
        else {
            End-Step -Index $currentStep -Status "FAIL" -Details "oci os ns get failed: $($nsResult.Output)"
        }
    }

    $currentStep = 4
    Start-Step -Index $currentStep
    if (-not $inputsValid) {
        End-Step -Index $currentStep -Status "SKIP" -Details "Skipped due input validation failure."
    }
    elseif (-not $ociAvailable) {
        End-Step -Index $currentStep -Status "FAIL" -Details "Cannot discover ADs because oci CLI is missing."
    }
    else {
        $adResult = Invoke-ExternalCapture -File "oci" -Arguments @(
            "iam", "availability-domain", "list",
            "--compartment-id", $TenancyOcid,
            "--profile", $Profile,
            "--region", $Region,
            "--query", "data[].name",
            "--raw-output"
        )
        if ($adResult.ExitCode -ne 0) {
            End-Step -Index $currentStep -Status "FAIL" -Details "AD discovery failed: $($adResult.Output)"
        }
        else {
            $ads = @(Convert-OciRawList -RawText $adResult.Output | Where-Object { $_ -match "-AD-" } | Sort-Object -Unique)
            if ($ads.Count -lt 1) {
                End-Step -Index $currentStep -Status "FAIL" -Details "AD discovery returned zero results."
            }
            else {
                if ($Deterministic) {
                    $adOrder = $ads
                }
                else {
                    $adOrder = @(Get-Random -InputObject $ads -Count $ads.Count)
                }
                End-Step -Index $currentStep -Status "PASS" -Details "Order: $($adOrder -join ', ')"
            }
        }
    }

    $currentStep = 5
    Start-Step -Index $currentStep
    if ($EnforceRegion) {
        if ($Region -eq $EnforceRegion) {
            End-Step -Index $currentStep -Status "PASS" -Details "Region '$Region' matches -EnforceRegion '$EnforceRegion'."
        }
        else {
            End-Step -Index $currentStep -Status "FAIL" -Details "Region '$Region' does not match -EnforceRegion '$EnforceRegion'."
        }
    }
    elseif ($Region -eq "eu-frankfurt-1") {
        End-Step -Index $currentStep -Status "PASS" -Details "Region '$Region' matches default recommendation."
    }
    else {
        End-Step -Index $currentStep -Status "WARN" -Details "Region '$Region' differs from default 'eu-frankfurt-1'. Continuing."
    }

    $currentStep = 6
    Start-Step -Index $currentStep
    if ($AllowedSshCidr) {
        if (Test-Ipv4Cidr -Value $AllowedSshCidr) {
            $effectiveAllowedSshCidr = $AllowedSshCidr
            End-Step -Index $currentStep -Status "PASS" -Details "Using caller-provided allowed_ssh_cidr=$effectiveAllowedSshCidr"
        }
        else {
            End-Step -Index $currentStep -Status "FAIL" -Details "Invalid IPv4 CIDR: $AllowedSshCidr"
        }
    }
    else {
        $detectedIp = Get-DetectedPublicIp
        if ($detectedIp) {
            $effectiveAllowedSshCidr = "$detectedIp/32"
            End-Step -Index $currentStep -Status "PASS" -Details "Detected $detectedIp. allowed_ssh_cidr=$effectiveAllowedSshCidr"
        }
        else {
            $effectiveAllowedSshCidr = "0.0.0.0/0"
            End-Step -Index $currentStep -Status "WARN" -Details "ipify unavailable. Using fallback allowed_ssh_cidr=0.0.0.0/0"
        }
    }

    $currentStep = 7
    Start-Step -Index $currentStep
    if (-not $inputsValid) {
        End-Step -Index $currentStep -Status "SKIP" -Details "Skipped due input validation failure."
    }
    elseif ([string]::IsNullOrWhiteSpace($sshPublicKey)) {
        End-Step -Index $currentStep -Status "FAIL" -Details "ssh_public_key content is empty."
    }
    elseif ([string]::IsNullOrWhiteSpace($effectiveAllowedSshCidr)) {
        End-Step -Index $currentStep -Status "FAIL" -Details "effective allowed_ssh_cidr is empty."
    }
    else {
        $tfvarsPath = Join-Path $projectRoot "terraform.auto.tfvars"
        $tfvarsLines = @(
            "compartment_ocid = $(Convert-ToTerraformStringLiteral -Value $CompartmentOcid)",
            "region = $(Convert-ToTerraformStringLiteral -Value $Region)",
            "oci_profile = $(Convert-ToTerraformStringLiteral -Value $Profile)",
            "name_prefix = $(Convert-ToTerraformStringLiteral -Value $NamePrefix)",
            "ssh_public_key = $(Convert-ToTerraformStringLiteral -Value $sshPublicKey)",
            "allowed_ssh_cidr = $(Convert-ToTerraformStringLiteral -Value $effectiveAllowedSshCidr)",
            "ssh_private_key_path_hint = $(Convert-ToTerraformStringLiteral -Value $privateKeyHint)",
            "ocpus = $Ocpus",
            "memory_in_gbs = $MemoryInGbs"
        )
        Set-Content -Path $tfvarsPath -Value ($tfvarsLines -join [Environment]::NewLine) -Encoding utf8NoBOM
        End-Step -Index $currentStep -Status "PASS" -Details "Wrote terraform.auto.tfvars at $tfvarsPath"
    }

    $currentStep = 8
    Start-Step -Index $currentStep
    if (-not $terraformAvailable) {
        End-Step -Index $currentStep -Status "FAIL" -Details "Cannot run terraform checks because terraform is missing."
    }
    else {
        $initResult = Invoke-ExternalCapture -File "terraform" -Arguments @("init", "-input=false", "-no-color")
        $tfFiles = @(
            Get-ChildItem -Path $projectRoot -Filter "*.tf" -File -Recurse |
            Sort-Object FullName |
            ForEach-Object { $_.FullName }
        )
        if ($tfFiles.Count -eq 0) {
            $fmtResult = [pscustomobject]@{
                ExitCode = 0
                Output   = "No .tf files found."
            }
        }
        else {
            $fmtArgs = @("fmt", "-check", "-no-color") + $tfFiles
            $fmtResult = Invoke-ExternalCapture -File "terraform" -Arguments $fmtArgs
        }
        $validateResult = Invoke-ExternalCapture -File "terraform" -Arguments @("validate", "-no-color")

        $details = "init=$($initResult.ExitCode), fmt=$($fmtResult.ExitCode), validate=$($validateResult.ExitCode)"
        if ($initResult.ExitCode -eq 0 -and $fmtResult.ExitCode -eq 0 -and $validateResult.ExitCode -eq 0) {
            End-Step -Index $currentStep -Status "PASS" -Details $details
        }
        else {
            $errorSummary = @()
            if ($initResult.ExitCode -ne 0) { $errorSummary += "init failed: $($initResult.Output)" }
            if ($fmtResult.ExitCode -ne 0) { $errorSummary += "fmt failed: $($fmtResult.Output)" }
            if ($validateResult.ExitCode -ne 0) { $errorSummary += "validate failed: $($validateResult.Output)" }
            End-Step -Index $currentStep -Status "FAIL" -Details (($details + " | " + ($errorSummary -join " ")) -replace "\s+", " ")
        }
    }

    $currentStep = 9
    Start-Step -Index $currentStep
    if (-not $inputsValid) {
        End-Step -Index $currentStep -Status "SKIP" -Details "Skipped due input validation failure."
    }
    elseif ($board[8 - 1].Status -eq "FAIL") {
        End-Step -Index $currentStep -Status "SKIP" -Details "Skipped because terraform init/fmt/validate failed."
    }
    elseif (-not $terraformAvailable) {
        End-Step -Index $currentStep -Status "FAIL" -Details "Cannot run apply because terraform is missing."
    }
    elseif ($adOrder.Count -lt 1) {
        End-Step -Index $currentStep -Status "FAIL" -Details "No AD candidates available for apply attempts."
    }
    else {
        $attemptTotal = $adOrder.Count
        $attemptNumber = 0
        foreach ($adName in $adOrder) {
            $attemptNumber++
            $remaining = $attemptTotal - $attemptNumber
            $attemptLabel = "Attempt $attemptNumber/$attemptTotal, AD=$adName, Remaining=$remaining"

            Set-StepStatus -Board $board -Index $currentStep -Status "RUNNING" -Details $attemptLabel
            Update-ProgressUi -Board $board -Activity $activity -CurrentIndex $currentStep -CurrentLabel $attemptLabel
            Show-StepBoard -Board $board -Title "apply-retry.ps1 step board"

            $applyResult = Invoke-ExternalCapture -File "terraform" -Arguments @(
                "apply",
                "-auto-approve",
                "-input=false",
                "-no-color",
                "-var", "availability_domain=$adName"
            )

            if ($applyResult.ExitCode -eq 0) {
                $applySucceeded = $true
                $adUsed = $adName
                End-Step -Index $currentStep -Status "PASS" -Details "Success on $attemptLabel"
                break
            }

            if ($applyResult.Output -match "(?i)Out of capacity for shape|Out of host capacity") {
                continue
            }

            Write-Host ""
            Write-Host "----- terraform apply non-capacity error output -----" -ForegroundColor Red
            Write-Host $applyResult.Output
            End-Step -Index $currentStep -Status "FAIL" -Details "Non-capacity error on $attemptLabel"
            break
        }

        if (-not $applySucceeded -and $board[$currentStep - 1].Status -ne "FAIL") {
            End-Step -Index $currentStep -Status "FAIL" -Details "All AD attempts exhausted due to capacity errors."
        }
    }

    $currentStep = 10
    Start-Step -Index $currentStep
    if (-not $applySucceeded) {
        End-Step -Index $currentStep -Status "SKIP" -Details "Skipped because apply did not succeed."
    }
    else {
        $instanceOcid = Get-TerraformOutputRaw -Name "instance_ocid"
        if (-not $adUsed) {
            $adUsed = Get-TerraformOutputRaw -Name "ad_used"
        }
        $publicIp = Get-TerraformOutputRaw -Name "public_ip"
        $privateIp = Get-TerraformOutputRaw -Name "private_ip"
        $sshCommand = Get-TerraformOutputRaw -Name "ssh_command_powershell"

        Write-Host ""
        Write-Host "Terraform outputs:" -ForegroundColor Green
        Write-Host "  instance_ocid          = $instanceOcid"
        Write-Host "  ad_used                = $adUsed"
        Write-Host "  public_ip              = $publicIp"
        Write-Host "  private_ip             = $privateIp"
        Write-Host "  ssh_command_powershell = $sshCommand"

        End-Step -Index $currentStep -Status "PASS" -Details "Outputs collected."
    }

    $currentStep = 11
    Start-Step -Index $currentStep
    if (-not $applySucceeded) {
        End-Step -Index $currentStep -Status "SKIP" -Details "Skipped because apply did not succeed."
    }
    elseif (-not $publicIp) {
        End-Step -Index $currentStep -Status "WARN" -Details "No public IP found; skipped Test-NetConnection."
    }
    elseif (-not (Get-Command Test-NetConnection -ErrorAction SilentlyContinue)) {
        End-Step -Index $currentStep -Status "WARN" -Details "Test-NetConnection not available; skipped SSH reachability test."
    }
    else {
        $deadline = (Get-Date).AddSeconds($SshWaitTimeoutSeconds)
        $checkAttempt = 0
        $reachable = $false
        while ((Get-Date) -lt $deadline) {
            $checkAttempt++
            $tnc = Test-NetConnection -ComputerName $publicIp -Port 22 -WarningAction SilentlyContinue
            if ($tnc.TcpTestSucceeded) {
                $reachable = $true
                break
            }
            Start-Sleep -Seconds 10
        }

        if ($reachable) {
            End-Step -Index $currentStep -Status "PASS" -Details "SSH port 22 reachable on $publicIp."
        }
        else {
            End-Step -Index $currentStep -Status "WARN" -Details "SSH port 22 not reachable within $SshWaitTimeoutSeconds seconds."
        }
    }

    $currentStep = 12
    Start-Step -Index $currentStep
    $summaryWarnings = @()
    if ($Ocpus -gt 1 -or $MemoryInGbs -gt 6) {
        $summaryWarnings += "Sizing warning: Ocpus=$Ocpus, MemoryInGbs=$MemoryInGbs (recommended 1/6)."
    }

    $hasFailure = Test-StepFailures -Board $board
    $hasWarnings = @($board | Where-Object { $_.Status -eq "WARN" }).Count -gt 0

    if ($hasFailure) {
        $summaryText = "One or more steps failed."
        if ($summaryWarnings.Count -gt 0) {
            $summaryText = "$summaryText $($summaryWarnings -join ' ')"
        }
        End-Step -Index $currentStep -Status "FAIL" -Details $summaryText
        $exitCode = 1
    }
    elseif ($hasWarnings -or $summaryWarnings.Count -gt 0) {
        $summaryText = "Completed with warnings."
        if ($summaryWarnings.Count -gt 0) {
            $summaryText = "$summaryText $($summaryWarnings -join ' ')"
        }
        End-Step -Index $currentStep -Status "WARN" -Details $summaryText
        $exitCode = 0
    }
    else {
        End-Step -Index $currentStep -Status "PASS" -Details "Completed successfully."
        $exitCode = 0
    }

    $summaryDone = $true
}
catch {
    $errorMessage = $_.Exception.Message
    if ($currentStep -ge 1 -and $currentStep -le $board.Count -and $board[$currentStep - 1].Status -eq "RUNNING") {
        Set-StepStatus -Board $board -Index $currentStep -Status "FAIL" -Details $errorMessage
        Show-StepBoard -Board $board -Title "apply-retry.ps1 step board"
    }

    if (-not $summaryDone) {
        Set-StepStatus -Board $board -Index 12 -Status "FAIL" -Details "Unhandled error: $errorMessage"
        Show-StepBoard -Board $board -Title "apply-retry.ps1 step board"
    }

    $exitCode = 1
}
finally {
    Finish-ProgressUi -Activity $activity
    Pop-Location
}

exit $exitCode

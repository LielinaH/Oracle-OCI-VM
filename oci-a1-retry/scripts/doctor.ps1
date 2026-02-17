[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$TenancyOcid,

    [string]$Region = "eu-frankfurt-1",
    [string]$Profile = "DEFAULT",
    [string]$OciCliPath,
    [string]$TerraformPath,
    [string]$AllowedSshCidr,
    [string]$EnforceRegion,
    [int]$Ocpus = 1,
    [int]$MemoryInGbs = 6
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
. "$PSScriptRoot\_common.ps1"

$OciCliPath = if ($OciCliPath) { $OciCliPath.Trim() } else { $null }
$TerraformPath = if ($TerraformPath) { $TerraformPath.Trim() } else { $null }
$originalOciCliSuppressPermWarning = $env:OCI_CLI_SUPPRESS_FILE_PERMISSIONS_WARNING
$ociCliSuppressPermWarningOverridden = $false

if ([string]::IsNullOrWhiteSpace($env:OCI_CLI_SUPPRESS_FILE_PERMISSIONS_WARNING)) {
    $env:OCI_CLI_SUPPRESS_FILE_PERMISSIONS_WARNING = "True"
    $ociCliSuppressPermWarningOverridden = $true
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

$steps = @(
    "Preflight: PowerShell 7+",
    "Preflight: terraform present",
    "Preflight: oci CLI present",
    "Auth indicator: oci os ns get (PASS/FAIL)",
    "Region policy check (default/warn; enforce option)",
    "AD discovery: oci iam availability-domain list (PASS if >=1 AD)",
    "Public IP detect (ipify) => allowed_ssh_cidr preview (WARN if unavailable)",
    "terraform init (PASS/FAIL)",
    "terraform fmt -check (PASS/FAIL)",
    "terraform validate (PASS/FAIL)",
    "Summary indicators (print final board + exit code)"
)

$activity = "doctor.ps1 progress"
$board = New-StepBoard -StepNames $steps
$projectRoot = Split-Path -Parent $PSScriptRoot
$exitCode = 1
$currentStep = 0
$summaryDone = $false
$terraformAvailable = $false
$terraformExecutable = ""
$ociAvailable = $false
$ociExecutable = ""

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
    Show-StepBoard -Board $board -Title "doctor.ps1 step board"
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
    $terraformExecutable = Resolve-TerraformExecutable -PreferredPath $TerraformPath
    if (-not [string]::IsNullOrWhiteSpace($terraformExecutable)) {
        $terraformAvailable = $true
        $tfVersion = Invoke-ExternalCapture -File $terraformExecutable -Arguments @("version")
        if ($tfVersion.ExitCode -eq 0) {
            $firstLine = ($tfVersion.Output -split "\r?\n")[0]
            End-Step -Index $currentStep -Status "PASS" -Details "$firstLine ($terraformExecutable)"
        }
        else {
            End-Step -Index $currentStep -Status "FAIL" -Details "terraform version failed: $($tfVersion.Output)"
        }
    }
    else {
        End-Step -Index $currentStep -Status "FAIL" -Details "terraform executable not found. Use -TerraformPath `"C:\Users\<you>\AppData\Local\Microsoft\WinGet\Links\terraform.exe`"."
    }

    $currentStep = 3
    Start-Step -Index $currentStep
    $ociExecutable = Resolve-OciExecutable -PreferredPath $OciCliPath
    if (-not [string]::IsNullOrWhiteSpace($ociExecutable)) {
        $ociAvailable = $true
        $ociVersion = Invoke-ExternalCapture -File $ociExecutable -Arguments @("-v")
        if ($ociVersion.ExitCode -eq 0) {
            End-Step -Index $currentStep -Status "PASS" -Details "$($ociVersion.Output.Trim()) ($ociExecutable)"
        }
        else {
            End-Step -Index $currentStep -Status "FAIL" -Details "oci -v failed: $($ociVersion.Output)"
        }
    }
    else {
        End-Step -Index $currentStep -Status "FAIL" -Details "oci CLI executable not found. Use -OciCliPath `"C:\Program Files (x86)\Oracle\oci_cli\oci.exe`"."
    }

    $currentStep = 4
    Start-Step -Index $currentStep
    if (-not $ociAvailable) {
        End-Step -Index $currentStep -Status "FAIL" -Details "Cannot run auth indicator because oci CLI is missing."
    }
    else {
        $nsResult = Invoke-ExternalCapture -File $ociExecutable -Arguments @(
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
    if ($board[4 - 1].Status -eq "FAIL") {
        End-Step -Index $currentStep -Status "SKIP" -Details "Skipped because auth indicator failed."
    }
    elseif (-not $ociAvailable) {
        End-Step -Index $currentStep -Status "FAIL" -Details "Cannot discover ADs because oci CLI is missing."
    }
    else {
        $adResult = Invoke-ExternalCapture -File $ociExecutable -Arguments @(
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
            $ads = @(Convert-OciRawList -RawText $adResult.Output | Sort-Object -Unique)
            $ads = @($ads | Where-Object { $_ -match "-AD-" } | Sort-Object -Unique)
            if ($ads.Count -ge 1) {
                End-Step -Index $currentStep -Status "PASS" -Details "Found $($ads.Count) AD(s): $($ads -join ', ')"
            }
            else {
                End-Step -Index $currentStep -Status "FAIL" -Details "AD discovery returned zero results."
            }
        }
    }

    $currentStep = 7
    Start-Step -Index $currentStep
    if ($AllowedSshCidr) {
        if (Test-Ipv4Cidr -Value $AllowedSshCidr) {
            End-Step -Index $currentStep -Status "PASS" -Details "allowed_ssh_cidr override: $AllowedSshCidr"
        }
        else {
            End-Step -Index $currentStep -Status "FAIL" -Details "Invalid IPv4 CIDR: $AllowedSshCidr"
        }
    }
    else {
        $detectedIp = Get-DetectedPublicIp
        if ($detectedIp) {
            End-Step -Index $currentStep -Status "PASS" -Details "Detected $detectedIp; preview allowed_ssh_cidr=$detectedIp/32"
        }
        else {
            End-Step -Index $currentStep -Status "WARN" -Details "ipify unavailable; preview allowed_ssh_cidr=0.0.0.0/0"
        }
    }

    $currentStep = 8
    Start-Step -Index $currentStep
    if (-not $terraformAvailable) {
        End-Step -Index $currentStep -Status "FAIL" -Details "Cannot run terraform init because terraform is missing."
    }
    else {
        $initResult = Invoke-ExternalCapture -File $terraformExecutable -Arguments @("init", "-input=false", "-no-color")
        if ($initResult.ExitCode -eq 0) {
            End-Step -Index $currentStep -Status "PASS" -Details "terraform init succeeded."
        }
        else {
            End-Step -Index $currentStep -Status "FAIL" -Details "terraform init failed: $($initResult.Output)"
        }
    }

    $currentStep = 9
    Start-Step -Index $currentStep
    if (-not $terraformAvailable) {
        End-Step -Index $currentStep -Status "FAIL" -Details "Cannot run terraform fmt -check because terraform is missing."
    }
    else {
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
            $fmtResult = Invoke-ExternalCapture -File $terraformExecutable -Arguments $fmtArgs
        }
        if ($fmtResult.ExitCode -eq 0) {
            End-Step -Index $currentStep -Status "PASS" -Details "terraform fmt -check succeeded."
        }
        else {
            End-Step -Index $currentStep -Status "FAIL" -Details "terraform fmt -check failed: $($fmtResult.Output)"
        }
    }

    $currentStep = 10
    Start-Step -Index $currentStep
    if (-not $terraformAvailable) {
        End-Step -Index $currentStep -Status "FAIL" -Details "Cannot run terraform validate because terraform is missing."
    }
    else {
        $validateResult = Invoke-ExternalCapture -File $terraformExecutable -Arguments @("validate", "-no-color")
        if ($validateResult.ExitCode -eq 0) {
            End-Step -Index $currentStep -Status "PASS" -Details "terraform validate succeeded."
        }
        else {
            End-Step -Index $currentStep -Status "FAIL" -Details "terraform validate failed: $($validateResult.Output)"
        }
    }

    $currentStep = 11
    Start-Step -Index $currentStep
    $warningDetails = @()
    if ($Ocpus -gt 1 -or $MemoryInGbs -gt 6) {
        $warningDetails += "Sizing warning: Ocpus=$Ocpus, MemoryInGbs=$MemoryInGbs (recommended 1/6)."
    }

    $hasFailure = Test-StepFailures -Board $board
    $hasWarnings = @($board | Where-Object { $_.Status -eq "WARN" }).Count -gt 0

    if ($hasFailure) {
        $summaryText = "One or more steps failed."
        if ($warningDetails.Count -gt 0) {
            $summaryText = "$summaryText $($warningDetails -join ' ')"
        }
        End-Step -Index $currentStep -Status "FAIL" -Details $summaryText
        $exitCode = 1
    }
    elseif ($hasWarnings -or $warningDetails.Count -gt 0) {
        $summaryText = "Completed with warnings."
        if ($warningDetails.Count -gt 0) {
            $summaryText = "$summaryText $($warningDetails -join ' ')"
        }
        End-Step -Index $currentStep -Status "WARN" -Details $summaryText
        $exitCode = 0
    }
    else {
        End-Step -Index $currentStep -Status "PASS" -Details "All checks passed."
        $exitCode = 0
    }

    $summaryDone = $true
}
catch {
    $errorMessage = $_.Exception.Message
    if ($currentStep -ge 1 -and $currentStep -le $board.Count -and $board[$currentStep - 1].Status -eq "RUNNING") {
        Set-StepStatus -Board $board -Index $currentStep -Status "FAIL" -Details $errorMessage
        Show-StepBoard -Board $board -Title "doctor.ps1 step board"
    }

    if (-not $summaryDone) {
        Set-StepStatus -Board $board -Index 11 -Status "FAIL" -Details "Unhandled error: $errorMessage"
        Show-StepBoard -Board $board -Title "doctor.ps1 step board"
    }

    $exitCode = 1
}
finally {
    Finish-ProgressUi -Activity $activity
    if ($ociCliSuppressPermWarningOverridden) {
        if ([string]::IsNullOrWhiteSpace($originalOciCliSuppressPermWarning)) {
            Remove-Item Env:OCI_CLI_SUPPRESS_FILE_PERMISSIONS_WARNING -ErrorAction SilentlyContinue
        }
        else {
            $env:OCI_CLI_SUPPRESS_FILE_PERMISSIONS_WARNING = $originalOciCliSuppressPermWarning
        }
    }
    Pop-Location
}

exit $exitCode

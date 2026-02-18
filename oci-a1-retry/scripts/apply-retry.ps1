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
    [string]$OciCliPath,
    [string]$TerraformPath,
    [switch]$AllowRootCompartment,
    [switch]$AllowExistingNamedResources,
    [switch]$ForceTakeLock,
    [string]$OciPrivateKeyPassword,
    [switch]$PromptOciPrivateKeyPassword,
    [int]$Ocpus = 1,
    [int]$MemoryInGbs = 6,
    [string]$Shape = "VM.Standard.A1.Flex",
    [switch]$AllowPaidShape,
    [string]$ImageOperatingSystem = "Canonical Ubuntu",
    [string]$ImageOperatingSystemVersion = "24.04"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
. "$PSScriptRoot\_common.ps1"

function Normalize-OcidInput {
    param(
        [string]$Value
    )

    if ([string]::IsNullOrWhiteSpace($Value)) {
        return ""
    }

    $normalized = $Value.Trim()
    $normalized = $normalized.Trim('"').Trim("'")
    $normalized = [regex]::Replace($normalized, "\s+", "")
    $normalized = [regex]::Replace($normalized, "\p{Cf}", "")
    return $normalized
}

$TenancyOcid = Normalize-OcidInput -Value $TenancyOcid
$CompartmentOcid = Normalize-OcidInput -Value $CompartmentOcid
$Region = $Region.Trim()
$Profile = $Profile.Trim()
$NamePrefix = $NamePrefix.Trim()
$AllowedSshCidr = if ($AllowedSshCidr) { $AllowedSshCidr.Trim() } else { $null }
$EnforceRegion = if ($EnforceRegion) { $EnforceRegion.Trim() } else { $null }
$OciCliPath = if ($OciCliPath) { $OciCliPath.Trim() } else { $null }
$TerraformPath = if ($TerraformPath) { $TerraformPath.Trim() } else { $null }
$OciPrivateKeyPassword = if ($OciPrivateKeyPassword) { $OciPrivateKeyPassword.Trim() } else { $null }
$Shape = if ($Shape) { $Shape.Trim() } else { "" }
$ImageOperatingSystem = if ($ImageOperatingSystem) { $ImageOperatingSystem.Trim() } else { "" }
$ImageOperatingSystemVersion = if ($ImageOperatingSystemVersion) { $ImageOperatingSystemVersion.Trim() } else { "" }
$originalOciCliSuppressPermWarning = $env:OCI_CLI_SUPPRESS_FILE_PERMISSIONS_WARNING
$ociCliSuppressPermWarningOverridden = $false

if ([string]::IsNullOrWhiteSpace($env:OCI_CLI_SUPPRESS_FILE_PERMISSIONS_WARNING)) {
    $env:OCI_CLI_SUPPRESS_FILE_PERMISSIONS_WARNING = "True"
    $ociCliSuppressPermWarningOverridden = $true
}

function Convert-SecureStringToPlainText {
    param(
        [Parameter(Mandatory = $true)]
        [SecureString]$SecureString
    )

    $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($SecureString)
    try {
        return [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr)
    }
    finally {
        [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)
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

function Convert-OciJsonSafe {
    param(
        [string]$RawText
    )

    $cleanLines = @(Get-CleanOciLines -RawText $RawText)
    if ($cleanLines.Count -eq 0) {
        return $null
    }

    $jsonText = $cleanLines -join [Environment]::NewLine
    try {
        return ($jsonText | ConvertFrom-Json)
    }
    catch {
        return $null
    }
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
        [string]$Name,
        [string]$Executable
    )

    $result = Invoke-ExternalCapture -File $Executable -Arguments @("output", "-raw", $Name)
    if ($result.ExitCode -ne 0) {
        return ""
    }
    return $result.Output.Trim()
}

function Convert-ToMarkdownCell {
    param(
        [string]$Value
    )

    if ($null -eq $Value) {
        return ""
    }

    $text = [string]$Value
    $text = $text.Replace("`r", " ").Replace("`n", " ")
    return $text.Replace("|", "\|")
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
$lockPath = Join-Path $projectRoot ".apply-retry.lock"
$lockHeld = $false
$exitCode = 1
$currentStep = 0
$summaryDone = $false
$runStartedUtc = [DateTime]::UtcNow
$runReportPath = ""
$latestRunReportPath = Join-Path $projectRoot "last-instance-details.md"

$ociAvailable = $false
$ociExecutable = ""
$terraformAvailable = $false
$terraformExecutable = ""
$stateHasManagedVcn = $false
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
$originalOciPrivateKeyPassword = $env:OCI_PRIVATE_KEY_PASSWORD
$originalOciCliPassphrase = $env:OCI_CLI_PASSPHRASE
$originalTfVarPrivateKeyPassword = $env:TF_VAR_private_key_password
$ociPrivateKeyPasswordOverridden = $false
$ociPrivateKeyPasswordSource = if (
    [string]::IsNullOrWhiteSpace($originalOciPrivateKeyPassword) -and
    [string]::IsNullOrWhiteSpace($originalOciCliPassphrase) -and
    [string]::IsNullOrWhiteSpace($originalTfVarPrivateKeyPassword)
) {
    "not-set"
}
else {
    "env"
}

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
    $validationWarnings = @()

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

    if (-not $TenancyOcid.StartsWith("ocid1.tenancy.", [System.StringComparison]::OrdinalIgnoreCase)) {
        $validationIssues += "TenancyOcid is not a valid tenancy OCID."
    }
    $isRootCompartment = $CompartmentOcid.StartsWith("ocid1.tenancy.", [System.StringComparison]::OrdinalIgnoreCase)
    if (
        -not $CompartmentOcid.StartsWith("ocid1.compartment.", [System.StringComparison]::OrdinalIgnoreCase) -and
        -not $isRootCompartment
    ) {
        $validationIssues += "CompartmentOcid must be a valid OCI compartment OCID."
    }
    elseif ($isRootCompartment -and -not $AllowRootCompartment) {
        $validationIssues += "Safety stop: root tenancy OCID was passed as CompartmentOcid. Use a dedicated child compartment, or override intentionally with -AllowRootCompartment."
    }
    elseif ($isRootCompartment -and $AllowRootCompartment) {
        $validationWarnings += "Root tenancy is being used as compartment because -AllowRootCompartment was provided."
    }
    if ($PromptOciPrivateKeyPassword -and -not [string]::IsNullOrWhiteSpace($OciPrivateKeyPassword)) {
        $validationIssues += "Use only one of -PromptOciPrivateKeyPassword or -OciPrivateKeyPassword."
    }
    if ([string]::IsNullOrWhiteSpace($Shape)) {
        $validationIssues += "Shape cannot be empty."
    }
    $isAlwaysFreeShape = $Shape.Equals("VM.Standard.A1.Flex", [System.StringComparison]::OrdinalIgnoreCase)
    if (-not $isAlwaysFreeShape -and -not $AllowPaidShape) {
        $validationIssues += "Safety stop: non-Always-Free shape '$Shape' requires -AllowPaidShape."
    }
    elseif (-not $isAlwaysFreeShape -and $AllowPaidShape) {
        $validationWarnings += "Paid shape mode enabled for '$Shape'. OCI charges may apply."
    }
    if ($Ocpus -lt 1) {
        $validationIssues += "Ocpus must be >= 1."
    }
    if ($MemoryInGbs -lt 1) {
        $validationIssues += "MemoryInGbs must be >= 1."
    }
    if ($isAlwaysFreeShape -and ($Ocpus -gt 4 -or $MemoryInGbs -gt 24)) {
        $validationWarnings += "Always Free A1 recommended limits are up to 4 OCPUs and 24 GB memory total."
    }
    if ([string]::IsNullOrWhiteSpace($ImageOperatingSystem)) {
        $validationIssues += "ImageOperatingSystem cannot be empty."
    }
    if ([string]::IsNullOrWhiteSpace($ImageOperatingSystemVersion)) {
        $validationIssues += "ImageOperatingSystemVersion cannot be empty."
    }

    $ociExecutable = Resolve-OciExecutable -PreferredPath $OciCliPath
    $ociAvailable = -not [string]::IsNullOrWhiteSpace($ociExecutable)
    $terraformExecutable = Resolve-TerraformExecutable -PreferredPath $TerraformPath
    $terraformAvailable = -not [string]::IsNullOrWhiteSpace($terraformExecutable)
    if (-not $ociAvailable) { $validationIssues += "oci CLI executable not found. Use -OciCliPath `"C:\Program Files (x86)\Oracle\oci_cli\oci.exe`"." }
    if (-not $terraformAvailable) { $validationIssues += "terraform executable not found. Use -TerraformPath `"C:\Users\<you>\AppData\Local\Microsoft\WinGet\Links\terraform.exe`"." }

    if ($validationIssues.Count -eq 0 -and (Test-Path -Path $lockPath)) {
        if ($ForceTakeLock) {
            Remove-Item -Path $lockPath -Force -ErrorAction SilentlyContinue
            $validationWarnings += "Existing lock file was removed due to -ForceTakeLock."
        }
        else {
            $lockInfo = ""
            if (Test-Path -Path $lockPath) {
                $lockInfo = (Get-Content -Path $lockPath -Raw -ErrorAction SilentlyContinue).Trim()
            }
            if ([string]::IsNullOrWhiteSpace($lockInfo)) {
                $validationIssues += "Safety stop: lock file exists at $lockPath. Another apply-retry process may still be running."
            }
            else {
                $validationIssues += "Safety stop: lock file exists at $lockPath. Another apply-retry process may still be running. Lock info: $lockInfo"
            }
        }
    }

    if ($validationIssues.Count -eq 0) {
        if ($PromptOciPrivateKeyPassword) {
            $securePassphrase = Read-Host "OCI API key passphrase (hidden)" -AsSecureString
            $plainPassphrase = Convert-SecureStringToPlainText -SecureString $securePassphrase
            if ([string]::IsNullOrWhiteSpace($plainPassphrase)) {
                if (
                    -not [string]::IsNullOrWhiteSpace($originalOciPrivateKeyPassword) -or
                    -not [string]::IsNullOrWhiteSpace($originalOciCliPassphrase) -or
                    -not [string]::IsNullOrWhiteSpace($originalTfVarPrivateKeyPassword)
                ) {
                    $ociPrivateKeyPasswordSource = "env"
                }
                else {
                    $ociPrivateKeyPasswordSource = "none"
                    $validationWarnings += "Prompted OCI API key passphrase was empty. Continuing without passphrase override."
                }
            }
            else {
                $env:OCI_PRIVATE_KEY_PASSWORD = $plainPassphrase
                $env:OCI_CLI_PASSPHRASE = $plainPassphrase
                $env:TF_VAR_private_key_password = $plainPassphrase
                $ociPrivateKeyPasswordOverridden = $true
                $ociPrivateKeyPasswordSource = "prompt"
            }
        }
        elseif (-not [string]::IsNullOrWhiteSpace($OciPrivateKeyPassword)) {
            $env:OCI_PRIVATE_KEY_PASSWORD = $OciPrivateKeyPassword
            $env:OCI_CLI_PASSPHRASE = $OciPrivateKeyPassword
            $env:TF_VAR_private_key_password = $OciPrivateKeyPassword
            $ociPrivateKeyPasswordOverridden = $true
            $ociPrivateKeyPasswordSource = "parameter"
        }
    }

    if ($validationIssues.Count -eq 0 -and $terraformAvailable) {
        $stateListResult = Invoke-ExternalCapture -File $terraformExecutable -Arguments @("state", "list")
        if ($stateListResult.ExitCode -eq 0) {
            $stateEntries = @(
                $stateListResult.Output -split "\r?\n" |
                ForEach-Object { $_.Trim() } |
                Where-Object { $_ -ne "" }
            )
            $stateHasManagedVcn = $stateEntries -contains "oci_core_vcn.main"
        }
        else {
            $validationWarnings += "Could not inspect terraform state list before apply: $($stateListResult.Output)"
        }
    }

    if ($validationIssues.Count -eq 0 -and $ociAvailable) {
        $vcnListResult = Invoke-ExternalCapture -File $ociExecutable -Arguments @(
            "network", "vcn", "list",
            "--compartment-id", $CompartmentOcid,
            "--all",
            "--profile", $Profile,
            "--region", $Region
        )

        if ($vcnListResult.ExitCode -eq 0) {
            $vcnDoc = Convert-OciJsonSafe -RawText $vcnListResult.Output
            if ($vcnDoc -and $vcnDoc.PSObject.Properties.Name -contains "data") {
                $targetVcnName = "$NamePrefix-vcn"
                $matchingNamedVcns = @(
                    $vcnDoc.data |
                    Where-Object {
                        $_."display-name" -eq $targetVcnName -and
                        $_."lifecycle-state" -ne "TERMINATED"
                    }
                )

                if ($matchingNamedVcns.Count -gt 1 -and -not $AllowExistingNamedResources) {
                    $validationIssues += "Safety stop: found $($matchingNamedVcns.Count) existing VCNs named '$targetVcnName' in compartment. This indicates duplicate stacks. Clean up first or rerun with -AllowExistingNamedResources."
                }
                elseif ($matchingNamedVcns.Count -ge 1 -and -not $stateHasManagedVcn -and -not $AllowExistingNamedResources) {
                    $validationIssues += "Safety stop: found existing VCN '$targetVcnName' but terraform state does not track oci_core_vcn.main. This can create duplicates. Run from the original state folder, import state, or rerun with -AllowExistingNamedResources."
                }
                elseif ($matchingNamedVcns.Count -ge 1 -and -not $stateHasManagedVcn -and $AllowExistingNamedResources) {
                    $validationWarnings += "Bypassing state/VCN safety guard because -AllowExistingNamedResources was provided."
                }
            }
            else {
                $validationWarnings += "Could not parse OCI VCN list output for duplicate-safety checks."
            }
        }
        else {
            $validationWarnings += "Could not run OCI VCN list duplicate-safety check: $($vcnListResult.Output)"
        }
    }

    if ($validationIssues.Count -eq 0) {
        $lockInfo = "pid=$PID; started_utc=$(([DateTime]::UtcNow).ToString('o')); script=apply-retry.ps1"
        try {
            Set-Content -Path $lockPath -Value $lockInfo -Encoding utf8NoBOM
            $lockHeld = $true
        }
        catch {
            $validationIssues += "Safety stop: unable to create lock file at $lockPath. $($_.Exception.Message)"
        }
    }

    if ($validationIssues.Count -gt 0) {
        $inputsValid = $false
        End-Step -Index $currentStep -Status "FAIL" -Details ($validationIssues -join " ")
    }
    elseif ($validationWarnings.Count -gt 0) {
        $inputsValid = $true
        $details = "Inputs validated with warning. Profile=$Profile. Shape=$Shape. Ocpus=$Ocpus. MemoryInGbs=$MemoryInGbs. Image=$ImageOperatingSystem $ImageOperatingSystemVersion. OCI passphrase source=$ociPrivateKeyPasswordSource. $($validationWarnings -join ' ')"
        End-Step -Index $currentStep -Status "WARN" -Details $details
    }
    else {
        $inputsValid = $true
        End-Step -Index $currentStep -Status "PASS" -Details "Inputs validated. Profile=$Profile. Shape=$Shape. Ocpus=$Ocpus. MemoryInGbs=$MemoryInGbs. Image=$ImageOperatingSystem $ImageOperatingSystemVersion. OCI passphrase source=$ociPrivateKeyPasswordSource. OCI CLI=$ociExecutable. Terraform=$terraformExecutable"
    }

    $currentStep = 3
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

    $currentStep = 4
    Start-Step -Index $currentStep
    if (-not $inputsValid) {
        End-Step -Index $currentStep -Status "SKIP" -Details "Skipped due input validation failure."
    }
    elseif ($board[3 - 1].Status -eq "FAIL") {
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
        $allowPaidShapeLiteral = if ($AllowPaidShape) { "true" } else { "false" }
        $tfvarsLines = @(
            "compartment_ocid = $(Convert-ToTerraformStringLiteral -Value $CompartmentOcid)",
            "region = $(Convert-ToTerraformStringLiteral -Value $Region)",
            "oci_profile = $(Convert-ToTerraformStringLiteral -Value $Profile)",
            "name_prefix = $(Convert-ToTerraformStringLiteral -Value $NamePrefix)",
            "shape = $(Convert-ToTerraformStringLiteral -Value $Shape)",
            "allow_paid_shape = $allowPaidShapeLiteral",
            "ssh_public_key = $(Convert-ToTerraformStringLiteral -Value $sshPublicKey)",
            "allowed_ssh_cidr = $(Convert-ToTerraformStringLiteral -Value $effectiveAllowedSshCidr)",
            "ssh_private_key_path_hint = $(Convert-ToTerraformStringLiteral -Value $privateKeyHint)",
            "image_operating_system = $(Convert-ToTerraformStringLiteral -Value $ImageOperatingSystem)",
            "image_operating_system_version = $(Convert-ToTerraformStringLiteral -Value $ImageOperatingSystemVersion)",
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
        $initResult = Invoke-ExternalCapture -File $terraformExecutable -Arguments @("init", "-input=false", "-no-color")
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
        $validateResult = Invoke-ExternalCapture -File $terraformExecutable -Arguments @("validate", "-no-color")

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
    elseif ($board[4 - 1].Status -in @("FAIL", "SKIP")) {
        End-Step -Index $currentStep -Status "SKIP" -Details "Skipped because AD discovery did not succeed."
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

            $applyResult = Invoke-ExternalCapture -File $terraformExecutable -Arguments @(
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

            $isCapacityError = $applyResult.Output -match "(?i)Out of capacity for shape|Out of host capacity"
            $isRetryableVnicPreparationError = $applyResult.Output -match "(?i)A problem occurred while preparing the instance's VNIC"

            if ($isCapacityError -or $isRetryableVnicPreparationError) {
                continue
            }

            Write-Host ""
            Write-Host "----- terraform apply non-capacity error output -----" -ForegroundColor Red
            Write-Host $applyResult.Output
            End-Step -Index $currentStep -Status "FAIL" -Details "Non-capacity error on $attemptLabel"
            break
        }

        if (-not $applySucceeded -and $board[$currentStep - 1].Status -ne "FAIL") {
            End-Step -Index $currentStep -Status "FAIL" -Details "All AD attempts exhausted due to retryable launch errors (capacity and/or transient VNIC provisioning errors)."
        }
    }

    $currentStep = 10
    Start-Step -Index $currentStep
    if (-not $applySucceeded) {
        End-Step -Index $currentStep -Status "SKIP" -Details "Skipped because apply did not succeed."
    }
    else {
        $instanceOcid = Get-TerraformOutputRaw -Name "instance_ocid" -Executable $terraformExecutable
        if (-not $adUsed) {
            $adUsed = Get-TerraformOutputRaw -Name "ad_used" -Executable $terraformExecutable
        }
        $publicIp = Get-TerraformOutputRaw -Name "public_ip" -Executable $terraformExecutable
        $privateIp = Get-TerraformOutputRaw -Name "private_ip" -Executable $terraformExecutable
        $sshCommand = Get-TerraformOutputRaw -Name "ssh_command_powershell" -Executable $terraformExecutable

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
    if (-not $Shape.Equals("VM.Standard.A1.Flex", [System.StringComparison]::OrdinalIgnoreCase)) {
        $summaryWarnings += "Paid shape warning: Shape=$Shape (charges may apply)."
    }
    if ($Ocpus -gt 1 -or $MemoryInGbs -gt 6) {
        $summaryWarnings += "Sizing warning: Ocpus=$Ocpus, MemoryInGbs=$MemoryInGbs (recommended 1/6)."
    }

    $hasFailure = Test-StepFailures -Board $board
    $hasWarnings = @($board | Where-Object { $_.Status -eq "WARN" }).Count -gt 0

    $summaryStatus = "PASS"
    $summaryText = ""
    if ($hasFailure) {
        $summaryStatus = "FAIL"
        $summaryText = "One or more steps failed."
        if ($summaryWarnings.Count -gt 0) {
            $summaryText = "$summaryText $($summaryWarnings -join ' ')"
        }
        $exitCode = 1
    }
    elseif ($hasWarnings -or $summaryWarnings.Count -gt 0) {
        $summaryStatus = "WARN"
        $summaryText = "Completed with warnings."
        if ($summaryWarnings.Count -gt 0) {
            $summaryText = "$summaryText $($summaryWarnings -join ' ')"
        }
        $exitCode = 0
    }
    else {
        $summaryStatus = "PASS"
        $summaryText = "Completed successfully."
        $exitCode = 0
    }

    if ($applySucceeded) {
        $runEndedUtc = [DateTime]::UtcNow
        $reportDirectory = Join-Path $projectRoot "reports"
        if (-not (Test-Path -Path $reportDirectory -PathType Container)) {
            New-Item -ItemType Directory -Path $reportDirectory -Force | Out-Null
        }

        $reportStamp = $runEndedUtc.ToString("yyyyMMdd-HHmmss")
        $runReportPath = Join-Path $reportDirectory "instance-$reportStamp.md"

        $reportLines = @(
            "# OCI Apply Run Report",
            "",
            "- Started (UTC): $($runStartedUtc.ToString('u'))",
            "- Ended (UTC): $($runEndedUtc.ToString('u'))",
            "- Summary status: $summaryStatus",
            "- Summary: $summaryText",
            "",
            "## Deployment",
            "- Compartment: $CompartmentOcid",
            "- Region: $Region",
            "- Profile: $Profile",
            "- Name Prefix: $NamePrefix",
            "- Shape: $Shape",
            "- OCPUs: $Ocpus",
            "- Memory (GB): $MemoryInGbs",
            "- Image: $ImageOperatingSystem $ImageOperatingSystemVersion",
            "",
            "## Instance",
            "- OCID: $instanceOcid",
            "- AD used: $adUsed",
            "- Public IP: $publicIp",
            "- Private IP: $privateIp",
            "",
            "## SSH",
            "- Command (PowerShell):",
            "```powershell",
            "$sshCommand",
            "```",
            "",
            "## Step Board",
            "| Index | Name | Status | Details |",
            "| --- | --- | --- | --- |"
        )

        foreach ($step in $board) {
            $cellName = Convert-ToMarkdownCell -Value $step.Name
            $cellStatus = Convert-ToMarkdownCell -Value $step.Status
            $cellDetails = Convert-ToMarkdownCell -Value $step.Details
            $reportLines += "| $($step.Index) | $cellName | $cellStatus | $cellDetails |"
        }

        Set-Content -Path $runReportPath -Value ($reportLines -join [Environment]::NewLine) -Encoding utf8NoBOM
        Set-Content -Path $latestRunReportPath -Value ($reportLines -join [Environment]::NewLine) -Encoding utf8NoBOM
        Write-Host "Run report written: $runReportPath" -ForegroundColor Cyan
        $summaryText = "$summaryText Run report: $runReportPath"
    }

    End-Step -Index $currentStep -Status $summaryStatus -Details $summaryText
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
    if ($lockHeld) {
        Remove-Item -Path $lockPath -Force -ErrorAction SilentlyContinue
        $lockHeld = $false
    }
    if ($ociPrivateKeyPasswordOverridden) {
        if ([string]::IsNullOrWhiteSpace($originalOciPrivateKeyPassword)) {
            Remove-Item Env:OCI_PRIVATE_KEY_PASSWORD -ErrorAction SilentlyContinue
        }
        else {
            $env:OCI_PRIVATE_KEY_PASSWORD = $originalOciPrivateKeyPassword
        }

        if ([string]::IsNullOrWhiteSpace($originalOciCliPassphrase)) {
            Remove-Item Env:OCI_CLI_PASSPHRASE -ErrorAction SilentlyContinue
        }
        else {
            $env:OCI_CLI_PASSPHRASE = $originalOciCliPassphrase
        }

        if ([string]::IsNullOrWhiteSpace($originalTfVarPrivateKeyPassword)) {
            Remove-Item Env:TF_VAR_private_key_password -ErrorAction SilentlyContinue
        }
        else {
            $env:TF_VAR_private_key_password = $originalTfVarPrivateKeyPassword
        }
    }
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

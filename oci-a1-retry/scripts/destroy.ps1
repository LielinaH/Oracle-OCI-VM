[CmdletBinding()]
param(
    [string]$Region = "eu-frankfurt-1",
    [string]$Profile = "DEFAULT",
    [bool]$AutoApprove = $true
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
. "$PSScriptRoot\_common.ps1"

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

$steps = @(
    "Preflight: PowerShell 7+",
    "terraform init",
    "terraform destroy",
    "Summary indicators"
)

$activity = "destroy.ps1 progress"
$board = New-StepBoard -StepNames $steps
$projectRoot = Split-Path -Parent $PSScriptRoot
$exitCode = 1
$currentStep = 0
$summaryDone = $false

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
    Show-StepBoard -Board $board -Title "destroy.ps1 step board"
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
    if (-not (Get-Command terraform -ErrorAction SilentlyContinue)) {
        End-Step -Index $currentStep -Status "FAIL" -Details "terraform not found on PATH."
    }
    else {
        $initResult = Invoke-ExternalCapture -File "terraform" -Arguments @("init", "-input=false", "-no-color")
        if ($initResult.ExitCode -eq 0) {
            End-Step -Index $currentStep -Status "PASS" -Details "terraform init succeeded."
        }
        else {
            End-Step -Index $currentStep -Status "FAIL" -Details "terraform init failed: $($initResult.Output)"
        }
    }

    $currentStep = 3
    Start-Step -Index $currentStep
    if (-not (Get-Command terraform -ErrorAction SilentlyContinue)) {
        End-Step -Index $currentStep -Status "FAIL" -Details "terraform not found on PATH."
    }
    else {
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
        if ($destroyResult.ExitCode -eq 0) {
            End-Step -Index $currentStep -Status "PASS" -Details "terraform destroy completed."
        }
        else {
            End-Step -Index $currentStep -Status "FAIL" -Details "terraform destroy failed: $($destroyResult.Output)"
        }
    }

    $currentStep = 4
    Start-Step -Index $currentStep
    if (Test-StepFailures -Board $board) {
        End-Step -Index $currentStep -Status "FAIL" -Details "One or more steps failed."
        $exitCode = 1
    }
    else {
        End-Step -Index $currentStep -Status "PASS" -Details "Destroy flow completed."
        $exitCode = 0
    }

    $summaryDone = $true
}
catch {
    $errorMessage = $_.Exception.Message
    if ($currentStep -ge 1 -and $currentStep -le $board.Count -and $board[$currentStep - 1].Status -eq "RUNNING") {
        Set-StepStatus -Board $board -Index $currentStep -Status "FAIL" -Details $errorMessage
        Show-StepBoard -Board $board -Title "destroy.ps1 step board"
    }

    if (-not $summaryDone) {
        Set-StepStatus -Board $board -Index 4 -Status "FAIL" -Details "Unhandled error: $errorMessage"
        Show-StepBoard -Board $board -Title "destroy.ps1 step board"
    }

    $exitCode = 1
}
finally {
    Finish-ProgressUi -Activity $activity
    Pop-Location
}

exit $exitCode

Set-StrictMode -Version Latest

function New-StepBoard {
    param(
        [Parameter(Mandatory = $true)]
        [string[]]$StepNames
    )

    $board = @()
    $index = 0
    foreach ($name in $StepNames) {
        $index++
        $board += [pscustomobject]@{
            Index   = $index
            Name    = $name
            Status  = "PENDING"
            Details = ""
        }
    }
    return $board
}

function Set-StepStatus {
    param(
        [Parameter(Mandatory = $true)]
        [object[]]$Board,
        [Parameter(Mandatory = $true)]
        [int]$Index,
        [Parameter(Mandatory = $true)]
        [ValidateSet("PENDING", "RUNNING", "PASS", "WARN", "FAIL", "SKIP")]
        [string]$Status,
        [string]$Details = ""
    )

    if ($Index -lt 1 -or $Index -gt $Board.Count) {
        throw "Step index $Index is out of range. Step count: $($Board.Count)."
    }

    $step = $Board[$Index - 1]
    $step.Status = $Status
    $step.Details = $Details
}

function Show-StepBoard {
    param(
        [Parameter(Mandatory = $true)]
        [object[]]$Board,
        [string]$Title = "Step Board"
    )

    Write-Host ""
    Write-Host "=== $Title ===" -ForegroundColor Cyan
    ($Board | Select-Object Index, Name, Status, Details | Format-Table -AutoSize | Out-String -Width 220).TrimEnd() | Write-Host
}

function Update-ProgressUi {
    param(
        [Parameter(Mandatory = $true)]
        [object[]]$Board,
        [Parameter(Mandatory = $true)]
        [string]$Activity,
        [Parameter(Mandatory = $true)]
        [int]$CurrentIndex,
        [Parameter(Mandatory = $true)]
        [string]$CurrentLabel
    )

    $totalSteps = [math]::Max($Board.Count, 1)
    $percent = [int](($CurrentIndex / $totalSteps) * 100)
    if ($percent -lt 0) { $percent = 0 }
    if ($percent -gt 100) { $percent = 100 }

    Write-Progress -Activity $Activity -Status $CurrentLabel -PercentComplete $percent
}

function Finish-ProgressUi {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Activity
    )

    Write-Progress -Activity $Activity -Completed
}

function Test-StepFailures {
    param(
        [Parameter(Mandatory = $true)]
        [object[]]$Board
    )

    return @($Board | Where-Object { $_.Status -eq "FAIL" }).Count -gt 0
}

function Resolve-OciExecutable {
    param(
        [string]$PreferredPath
    )

    $candidates = @()

    if (-not [string]::IsNullOrWhiteSpace($PreferredPath)) {
        $candidates += $PreferredPath
    }

    if ($env:ProgramFiles -and $env:ProgramFiles.Trim() -ne "") {
        $candidates += (Join-Path $env:ProgramFiles "Oracle\oci_cli\oci.exe")
    }
    if (${env:ProgramFiles(x86)} -and ${env:ProgramFiles(x86)}.Trim() -ne "") {
        $candidates += (Join-Path ${env:ProgramFiles(x86)} "Oracle\oci_cli\oci.exe")
    }

    foreach ($commandName in @("oci.exe", "oci")) {
        $command = Get-Command $commandName -ErrorAction SilentlyContinue
        if ($command -and $command.CommandType -eq "Application") {
            $commandPath = if ($command.Path) { $command.Path } elseif ($command.Source) { $command.Source } else { "" }
            if (-not [string]::IsNullOrWhiteSpace($commandPath)) {
                $candidates += $commandPath
            }
        }
    }

    try {
        $whereResults = @(where.exe oci.exe 2>$null)
        if ($whereResults.Count -gt 0) {
            $candidates += $whereResults
        }
    }
    catch {
        # Ignore where.exe failures.
    }

    foreach ($candidate in ($candidates | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne "" } | Select-Object -Unique)) {
        if (Test-Path -Path $candidate -PathType Leaf) {
            return (Resolve-Path -Path $candidate).Path
        }
    }

    return ""
}

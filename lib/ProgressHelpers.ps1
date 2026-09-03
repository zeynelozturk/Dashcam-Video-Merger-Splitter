$script:ProgressEnabled = $true

$script:ProgressWeights = [ordered]@{
    Setup = 5
    QuickValidation = 10
    AudioMetadata = 15
    FrameHashes = 25
    PairProcessing = 20
    VideoFinalize = 10
    AudioFinalize = 15
}

$script:StageProgress = @{}
foreach ($stageName in $script:ProgressWeights.Keys) {
    $script:StageProgress[$stageName] = 0.0
}

function Set-OverallProgress {
    param(
        [string]$Stage,
        [double]$PercentComplete,
        [string]$Status
    )

    if (-not $script:ProgressEnabled) {
        return
    }

    if (-not $script:ProgressWeights.Contains($Stage)) {
        return
    }

    $clamped = [Math]::Max(0.0, [Math]::Min(100.0, $PercentComplete))
    $script:StageProgress[$Stage] = $clamped

    $overall = 0.0
    foreach ($stageName in $script:ProgressWeights.Keys) {
        $weight = [double]$script:ProgressWeights[$stageName]
        $stageValue = [double]$script:StageProgress[$stageName]
        $overall += $weight * ($stageValue / 100.0)
    }

    Write-Progress `
        -Id 1 `
        -Activity "Dashcam merge overall progress" `
        -Status $Status `
        -PercentComplete ([Math]::Round($overall, 1))
}

function Set-StepProgress {
    param(
        [string]$Activity,
        [string]$Status,
        [double]$PercentComplete
    )

    if (-not $script:ProgressEnabled) {
        return
    }

    Write-Progress `
        -Id 2 `
        -Activity $Activity `
        -Status $Status `
        -PercentComplete ([Math]::Max(0.0, [Math]::Min(100.0, $PercentComplete)))
}

function Complete-StepProgress {
    param(
        [string]$Activity
    )

    if (-not $script:ProgressEnabled) {
        return
    }

    Write-Progress -Id 2 -Activity $Activity -Completed
}

function Complete-AllProgress {
    if (-not $script:ProgressEnabled) {
        return
    }

    Write-Progress -Id 2 -Activity "Current step" -Completed
    Write-Progress -Id 1 -Activity "Dashcam merge overall progress" -Completed
}

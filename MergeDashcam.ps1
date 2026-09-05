param(
    [Parameter(ValueFromRemainingArguments = $true)]
    [string[]]$Files,

    [switch]$ExcludeAudio
)

$ErrorActionPreference = "Stop"

# ============================================================
# Settings
# ============================================================

$configPath = Join-Path $PSScriptRoot "MergeDashcam.config.psd1"
if (-not (Test-Path -LiteralPath $configPath -PathType Leaf)) {
    throw "Configuration file not found: $configPath"
}

$config = Import-PowerShellDataFile -LiteralPath $configPath
$requiredSettings = @(
    "FFmpegPath",
    "FFprobePath",
    "MinimumMatchFrames",
    "RecordingFilePrefix",
    "EventFilePrefix",
    "FrameRate",
    "FrameRateWarningDifference",
    "UseParallelFrameHashing",
    "ParallelFrameHashWorkers",
    "UseParallelAudioMetadata",
    "ParallelAudioMetadataWorkers",
    "EnableAudioBoundaryRepair",
    "AudioBoundaryRepairTailSeconds",
    "AudioBoundaryRepairMaximumGapSeconds",
    "AudioBoundaryRepairCompensationSeconds",
    "AudioBoundaryRepairFadeSeconds",
    "QuickValidationSeconds",
    "MinimalConsoleOutput",
    "SuppressFFmpegConsoleOutput"
)

foreach ($settingName in $requiredSettings) {
    if (-not $config.ContainsKey($settingName)) {
        throw "Missing setting '$settingName' in: $configPath"
    }
}

$ffmpeg = [string]$config.FFmpegPath
$ffprobe = [string]$config.FFprobePath
$MinimumMatchFrames = [int]$config.MinimumMatchFrames
$RecordingFilePrefix = [string]$config.RecordingFilePrefix
$EventFilePrefix = [string]$config.EventFilePrefix
$FrameRateValue = [double]$config.FrameRate
$FrameRateWarningDifference = [double]$config.FrameRateWarningDifference
$UseParallelFrameHashing = [bool]$config.UseParallelFrameHashing
$ParallelFrameHashWorkers = [int]$config.ParallelFrameHashWorkers
$UseParallelAudioMetadata = [bool]$config.UseParallelAudioMetadata
$ParallelAudioMetadataWorkers = [int]$config.ParallelAudioMetadataWorkers
$EnableAudioBoundaryRepair = [bool]$config.EnableAudioBoundaryRepair
$AudioBoundaryRepairTailSeconds =
    [double]$config.AudioBoundaryRepairTailSeconds
$AudioBoundaryRepairMaximumGapSeconds =
    [double]$config.AudioBoundaryRepairMaximumGapSeconds
$AudioBoundaryRepairCompensationSeconds =
    [double]$config.AudioBoundaryRepairCompensationSeconds
$AudioBoundaryRepairFadeSeconds =
    [double]$config.AudioBoundaryRepairFadeSeconds
$QuickValidationSeconds = [double]$config.QuickValidationSeconds
$MinimalConsoleOutput = [bool]$config.MinimalConsoleOutput
$SuppressFFmpegConsoleOutput = [bool]$config.SuppressFFmpegConsoleOutput

if ($FrameRateValue -le 0) {
    throw "FrameRate must be greater than zero in: $configPath"
}

if ($AudioBoundaryRepairTailSeconds -le 0) {
    throw "AudioBoundaryRepairTailSeconds must be greater than zero in: $configPath"
}

if ($AudioBoundaryRepairMaximumGapSeconds -lt 0) {
    throw "AudioBoundaryRepairMaximumGapSeconds cannot be negative in: $configPath"
}

if ($AudioBoundaryRepairCompensationSeconds -lt 0) {
    throw "AudioBoundaryRepairCompensationSeconds cannot be negative in: $configPath"
}

if ($AudioBoundaryRepairFadeSeconds -lt 0) {
    throw "AudioBoundaryRepairFadeSeconds cannot be negative in: $configPath"
}

if ([string]::IsNullOrWhiteSpace($RecordingFilePrefix) -or
    [string]::IsNullOrWhiteSpace($EventFilePrefix)) {
    throw "RecordingFilePrefix and EventFilePrefix cannot be empty in: $configPath"
}

$FrameRate = $FrameRateValue.ToString(
    "0.######",
    [Globalization.CultureInfo]::InvariantCulture
)

# ============================================================
# Load helper modules
# ============================================================

. (Join-Path $PSScriptRoot "lib\ConsoleHelpers.ps1")
. (Join-Path $PSScriptRoot "lib\FFmpegHelpers.ps1")
. (Join-Path $PSScriptRoot "lib\ProgressHelpers.ps1")
. (Join-Path $PSScriptRoot "lib\StorageHelpers.ps1")
. (Join-Path $PSScriptRoot "lib\BinaryHelpers.ps1")
. (Join-Path $PSScriptRoot "lib\FrameMetadata.ps1")
. (Join-Path $PSScriptRoot "lib\OverlapDetection.ps1")
. (Join-Path $PSScriptRoot "lib\InputSorting.ps1")
. (Join-Path $PSScriptRoot "lib\OutputSelection.ps1")
. (Join-Path $PSScriptRoot "lib\AudioSegments.ps1")

try {
    $ffmpeg = Resolve-ExecutablePath `
        -ConfiguredPath $ffmpeg `
        -ExecutableFileName "ffmpeg.exe" `
        -ToolLabel "FFmpeg" `
        -ConfigSettingName "FFmpegPath"

    $ffprobe = Resolve-ExecutablePath `
        -ConfiguredPath $ffprobe `
        -ExecutableFileName "ffprobe.exe" `
        -ToolLabel "FFprobe" `
        -ConfigSettingName "FFprobePath"
}
catch {
    Write-Host ""
    Write-Host "FAILED:"
    Write-Host $_.Exception.Message

    Wait-ForUserExit "Press Enter to close."
    exit 1
}

# ============================================================
# Validate input
# ============================================================

if ($null -eq $Files) {
    $Files = @()
}

$primaryInputResolution = $null

while ($null -eq $primaryInputResolution) {
    if ($Files.Count -eq 0) {
        Write-Host ""
        Write-Host "Provide initial input in one of these ways:"
        Write-Host "- Drag one folder (top-level files only, no subfolders)"
        Write-Host "- Drag at least two files"
        Write-Host "Do not mix folders and files in the same selection."

        $draggedText = Read-HostWithSpacing "Input"
        if ([string]::IsNullOrWhiteSpace($draggedText)) {
            continue
        }

        $Files = @(Convert-DraggedFileList $draggedText)
        if ($Files.Count -eq 0) {
            Write-Host "No paths were detected. Please try again."
            continue
        }
    }

    try {
        $primaryInputResolution = Resolve-PrimaryInputFiles -InputPaths $Files
    }
    catch {
        Write-Host ""
        Write-Host "Input selection is not valid."
        Write-Host $_.Exception.Message
        $Files = @()
    }
}

$Files = @($primaryInputResolution.Files)

$initialSort = Get-SortedInputFileInfos -FilePaths $Files
$initialFiles = @($initialSort.Items)

Write-Host ""
Write-Host "Initial files after sorting:"
if ($primaryInputResolution.InputMode -eq "Folder") {
    Write-Host "Input mode: Folder"
    Write-Host "Folder: $($primaryInputResolution.SourceFolder)"
}
else {
    Write-Host "Input mode: Files"
}
Write-Host (
    "Sort mode: " +
    $initialSort.SortMode +
    " (parsed " +
    $initialSort.ParseableCount +
    "/" +
    $initialSort.TotalCount +
    ")"
)
Write-Host (
    "First: $($initialFiles[0].Name) - " +
    $initialFiles[0].LastWriteTime.ToString("yyyy-MM-dd HH:mm:ss")
)
Write-Host (
    "Last : $($initialFiles[$initialFiles.Count - 1].Name) - " +
    $initialFiles[$initialFiles.Count - 1].LastWriteTime.ToString("yyyy-MM-dd HH:mm:ss")
)

$Files = @(
    $initialFiles |
        ForEach-Object {
            $_.FullName
        }
)

$additionalText = Read-HostWithSpacing (
    "Do you want to add additional files (like event videos)? " +
    "Drag files here and press Enter, or press Enter to skip " +
    "(folders are not accepted here)"
)

if (-not [string]::IsNullOrWhiteSpace($additionalText)) {

    $additionalFiles = Convert-DraggedFileList $additionalText

    $additionalItems = @(
        $additionalFiles |
            Where-Object {
                -not [string]::IsNullOrWhiteSpace([string]$_)
            } |
            ForEach-Object {
                Get-Item -LiteralPath ([string]$_)
            }
    )

    $additionalFolders = @(
        $additionalItems |
            Where-Object {
                $_.PSIsContainer
            }
    )

    if ($additionalFolders.Count -gt 0) {
        throw (
            "Additional/event input accepts files only. " +
            "Folders are not accepted in this step."
        )
    }

    $allFilePaths = @($Files) + @($additionalFiles)

    $additionalSort = Get-SortedInputFileInfos -FilePaths $allFilePaths

    Write-Host ""
    Write-Host (
        "Sort mode after adding files: " +
        $additionalSort.SortMode +
        " (parsed " +
        $additionalSort.ParseableCount +
        "/" +
        $additionalSort.TotalCount +
        ")"
    )

    $Files = @(
        $additionalSort.Items |
            ForEach-Object {
                $_.FullName
            }
    )
}

foreach ($file in $Files) {

    if (-not (Test-Path -LiteralPath $file -PathType Leaf)) {
        throw "File not found: $file"
    }
}

if (-not $ExcludeAudio) {
    while ($true) {
        $audioChoice = Read-HostWithSpacing "Include audio? (Y/n, press Enter for Y)"

        if ([string]::IsNullOrWhiteSpace($audioChoice)) {
            break
        }

        $normalizedAudioChoice = $audioChoice.Trim().ToUpperInvariant()
        if ($normalizedAudioChoice -eq "Y" -or
            $normalizedAudioChoice -eq "YES") {
            break
        }
        if ($normalizedAudioChoice -eq "N" -or
            $normalizedAudioChoice -eq "NO") {
            $ExcludeAudio = $true
            break
        }

        Write-Host "Please enter Y or N."
    }
}

$OutputDirectory = Select-OutputDirectory (
    Split-Path $Files[0] -Parent
)

Set-OverallProgress `
    -Stage "Setup" `
    -PercentComplete 100 `
    -Status "Setup complete"

# ============================================================
# Header
# ============================================================

Write-Host ""
Write-Host "Dashcam merge"
Write-Host "============="
Write-Host ""

foreach ($file in $Files) {
    Write-Host "Input: $file"
}

# ============================================================
# Temporary directory
# ============================================================

$tempRoot = $null
$tempBaseDirectory = $null
$usedTempFallback = $false

$firstName =
    [IO.Path]::GetFileNameWithoutExtension($Files[0])

$resultFile = Join-Path (
    $OutputDirectory
) ($firstName + "_merged_result.txt")

$report = New-Object System.Collections.Generic.List[string]
$mergeSucceeded = $false

$report.Add("Dashcam merge result")
$report.Add("===================")
$report.Add("")

foreach ($file in $Files) {
    $report.Add("Input: $file")
}

$report.Add("")

try {

    $spacePlan = Assert-MergeFreeSpace `
        -InputFiles $Files `
        -OutputDirectory $OutputDirectory `
        -TempDirectory $env:TEMP `
        -IncludeAudio (-not $ExcludeAudio)

    $tempBaseDirectory = [string]$spacePlan.SelectedTempBaseDirectory
    $usedTempFallback = [bool]$spacePlan.UsedTempFallback

    if (-not (Test-Path -LiteralPath $tempBaseDirectory -PathType Container)) {
        New-Item -ItemType Directory -Path $tempBaseDirectory -Force | Out-Null
    }

    $tempRoot = Join-Path $tempBaseDirectory (
        "dashcam_merge_" + [guid]::NewGuid().ToString("N")
    )

    New-Item -ItemType Directory -Path $tempRoot | Out-Null

    if ($usedTempFallback) {
        $report.Add("")
        $report.Add("TEMP fallback selected: $tempBaseDirectory")
    }

    Write-Host ""
    Write-Host "Merging in progress..."

    Set-StepProgress `
        -Activity "Starting merge" `
        -Status "Preparing stages" `
        -PercentComplete 0

    # ========================================================
    # Quick pre-check and optional skip
    # ========================================================

    $quickCheckFailed =
        New-Object System.Collections.Generic.List[object]
    $quickCheckPassed =
        New-Object System.Collections.Generic.List[string]

    $quickTotal = [Math]::Max(1, $Files.Count)

    Set-StepProgress `
        -Activity "Quick file validation" `
        -Status "0/$quickTotal files" `
        -PercentComplete 0

    Set-OverallProgress `
        -Stage "QuickValidation" `
        -PercentComplete 0 `
        -Status "Quick validation: 0/$quickTotal"

    $quickProcessed = 0
    foreach ($file in $Files) {
        $check = Test-QuickVideoValidity `
            -File $file `
            -DecodeSeconds $QuickValidationSeconds

        if ($check.IsValid) {
            [void]$quickCheckPassed.Add($file)
        }
        else {
            [void]$quickCheckFailed.Add(
                [PSCustomObject]@{
                    File = $file
                    Stage = [string]$check.Stage
                    Detail = [string]$check.Detail
                }
            )
        }

        $quickProcessed++
        $quickPercent = 100.0 * $quickProcessed / $quickTotal

        Set-StepProgress `
            -Activity "Quick file validation" `
            -Status "$quickProcessed/$quickTotal files" `
            -PercentComplete $quickPercent

        Set-OverallProgress `
            -Stage "QuickValidation" `
            -PercentComplete $quickPercent `
            -Status "Quick validation: $quickProcessed/$quickTotal"
    }

    Complete-StepProgress -Activity "Quick file validation"

    if ($quickCheckFailed.Count -gt 0) {
        Write-Host ""
        Write-Host "Quick validation found problematic files:"

        foreach ($failed in $quickCheckFailed) {
            Write-Host (
                "- " +
                [IO.Path]::GetFileName([string]$failed.File) +
                " | " +
                [string]$failed.Stage +
                " | " +
                [string]$failed.Detail
            )
        }

        Write-Host ""
        Write-Host "Suggestion: run chkdsk on the source drive, then retry."

        $report.Add("Quick validation failed files:")
        foreach ($failed in $quickCheckFailed) {
            $report.Add(
                "- " +
                [string]$failed.File +
                " | " +
                [string]$failed.Stage +
                " | " +
                [string]$failed.Detail
            )
        }
        $report.Add("")

        $continueWithSkips = $false
        while ($true) {
            $answer = Read-HostWithSpacing "Continue by skipping failed files? [Y/N]"
            if ([string]::IsNullOrWhiteSpace($answer)) {
                continue
            }

            $normalized = $answer.Trim().ToUpperInvariant()
            if ($normalized -eq "Y" -or $normalized -eq "YES") {
                $continueWithSkips = $true
                break
            }
            if ($normalized -eq "N" -or $normalized -eq "NO") {
                break
            }
        }

        if (-not $continueWithSkips) {
            throw (
                "Quick validation failed for " +
                $quickCheckFailed.Count +
                " file(s). Run chkdsk on the source drive and retry."
            )
        }

        $Files = @($quickCheckPassed.ToArray())

        $report.Add("Skipped files (continued without them):")
        foreach ($failed in $quickCheckFailed) {
            $report.Add([string]$failed.File)
        }
        $report.Add("")

        if ($Files.Count -lt 2) {
            throw "Not enough valid files remain after skipping invalid files. Need at least 2."
        }
    }

    $detectedFrameRate = Get-DetectedVideoFrameRate $Files[0]
    if (
        $null -ne $detectedFrameRate -and
        [Math]::Abs($detectedFrameRate - $FrameRateValue) -gt
            $FrameRateWarningDifference
    ) {
        $detectedFrameRateText = $detectedFrameRate.ToString(
            "0.###",
            [Globalization.CultureInfo]::InvariantCulture
        )

        Write-Host ""
        Write-Host "WARNING: The first video reports $detectedFrameRateText fps."
        Write-Host "The merger is configured to use $FrameRate fps."
        Write-Host (
            "If $detectedFrameRateText fps is the video's real frame rate, " +
            "update FrameRate in MergeDashcam.config.psd1."
        )
        Write-Host "Some damaged or incorrectly muxed files report the wrong rate."

        $report.Add("")
        $report.Add(
            "WARNING: First video reports $detectedFrameRateText fps; " +
            "configured rate is $FrameRate fps."
        )

        while ($true) {
            $answer = Read-HostWithSpacing "Continue using $FrameRate fps anyway? [Y/N]"
            if ([string]::IsNullOrWhiteSpace($answer)) {
                continue
            }

            $normalized = $answer.Trim().ToUpperInvariant()
            if ($normalized -eq "Y" -or $normalized -eq "YES") {
                $report.Add("User continued using $FrameRate fps.")
                break
            }
            if ($normalized -eq "N" -or $normalized -eq "NO") {
                throw "Merge cancelled because the reported frame rate differs significantly."
            }
        }
    }

    $fileMetadataCache = @{}
    $overlapCache = @{}

    # ========================================================
    # Read media metadata
    # ========================================================

    $audioAvailable =
        New-Object System.Collections.Generic.List[bool]
    $audioStreamIndices =
        New-Object System.Collections.Generic.List[int]

    if (
        $UseParallelAudioMetadata -and
        $ParallelAudioMetadataWorkers -gt 1 -and
        $Files.Count -gt 1
    ) {
        try {
            Write-InfoBlank
            Write-Info (
                "Reading media metadata in parallel " +
                "($ParallelAudioMetadataWorkers workers)..."
            )

            $parallelAudioMetadata = Get-FileMetadataParallel `
                -InputFiles $Files `
                -WorkerCount $ParallelAudioMetadataWorkers `
                -FfprobePath $ffprobe `
                -ProgressStage "AudioMetadata" `
                -ProgressActivity "Reading media metadata"

            for ($i = 0; $i -lt $Files.Count; $i++) {
                $metadataCacheKey = [IO.Path]::GetFullPath($Files[$i])
                $fileMetadataCache[$metadataCacheKey] =
                    $parallelAudioMetadata[$i]
            }
        }
        catch {
            Write-Host ""
            Write-Host (
                "Parallel media metadata failed; " +
                "falling back to sequential mode."
            )

            $report.Add("")
            $report.Add(
                "Parallel media metadata failed; used sequential fallback."
            )
        }
    }

    $audioProcessedCount = 0
    $audioTotalCount = [Math]::Max(1, $Files.Count)

    Set-StepProgress `
        -Activity "Reading media metadata" `
        -Status "0/$audioTotalCount files" `
        -PercentComplete 0

    Set-OverallProgress `
        -Stage "AudioMetadata" `
        -PercentComplete 0 `
        -Status "Media metadata: 0/$audioTotalCount"

    foreach ($file in $Files) {

        $metadataCacheKey = [IO.Path]::GetFullPath($file)

        if (-not $fileMetadataCache.ContainsKey($metadataCacheKey)) {
            $fileMetadataCache[$metadataCacheKey] =
                Get-FileMetadata $file
        }

        $audioStreamIndex =
            [int]$fileMetadataCache[$metadataCacheKey].PcmStreamIndex

        $hasAudio = ($audioStreamIndex -ge 0)
        [void]$audioAvailable.Add($hasAudio)
        [void]$audioStreamIndices.Add($audioStreamIndex)

        if ($hasAudio) {
            Write-Info (
                "Audio: YES  " +
                "stream=$audioStreamIndex  " +
                "$([IO.Path]::GetFileName($file))"
            )
            $report.Add(
                "Audio: YES  stream=$audioStreamIndex  " +
                "$([IO.Path]::GetFileName($file))"
            )
        }
        else {
            Write-Info "Audio: NO   $([IO.Path]::GetFileName($file))"
            $report.Add(
                "Audio: NO   $([IO.Path]::GetFileName($file))"
            )
        }

        $audioProcessedCount++
        $audioPercent = 100.0 * $audioProcessedCount / $audioTotalCount

        Set-StepProgress `
            -Activity "Reading media metadata" `
            -Status "$audioProcessedCount/$audioTotalCount files" `
            -PercentComplete $audioPercent

        Set-OverallProgress `
            -Stage "AudioMetadata" `
            -PercentComplete $audioPercent `
            -Status "Media metadata: $audioProcessedCount/$audioTotalCount"
    }

    Complete-StepProgress -Activity "Reading media metadata"

    # ========================================================
    # Generate frame hashes
    # ========================================================

    $hashes = @{}

    $usedParallelFrameHashing = $false

    if (
        $UseParallelFrameHashing -and
        $ParallelFrameHashWorkers -gt 1 -and
        $Files.Count -gt 1
    ) {
        try {
            Write-InfoBlank
            Write-Info (
                "Creating frame hashes in parallel " +
                "($ParallelFrameHashWorkers workers)..."
            )

            $parallelHashes = Get-FrameHashesParallel `
                -InputFiles $Files `
                -WorkerCount $ParallelFrameHashWorkers `
                -FfmpegPath $ffmpeg `
                -ProgressStage "FrameHashes" `
                -ProgressActivity "Generating frame hashes"

            for ($i = 0; $i -lt $Files.Count; $i++) {
                $hashes[$i] = @($parallelHashes[$i])

                Write-InfoBlank
                Write-Info "Creating frame hashes:"
                Write-Info "  $([IO.Path]::GetFileName($Files[$i]))"
                Write-Info "  Frames: $(@($hashes[$i]).Count)"
            }

            $usedParallelFrameHashing = $true
        }
        catch {
            if ($_.Exception.Message -like "Could not calculate frame hashes for:*") {
                throw
            }

            Write-Host ""
            Write-Host (
                "Parallel hash generation failed; " +
                "falling back to sequential mode."
            )

            $report.Add("")
            $report.Add(
                "Parallel hash generation failed; used sequential fallback."
            )
        }
    }

    if (-not $usedParallelFrameHashing) {
        $hashProcessedCount = 0
        $hashTotalCount = [Math]::Max(1, $Files.Count)

        Set-StepProgress `
            -Activity "Generating frame hashes" `
            -Status "0/$hashTotalCount files" `
            -PercentComplete 0

        Set-OverallProgress `
            -Stage "FrameHashes" `
            -PercentComplete 0 `
            -Status "Frame hashes: 0/$hashTotalCount"

        for ($i = 0; $i -lt $Files.Count; $i++) {

            Write-InfoBlank
            Write-Info "Creating frame hashes:"
            Write-Info "  $([IO.Path]::GetFileName($Files[$i]))"

            $hashes[$i] = Get-FrameHashes $Files[$i]

            Write-Info "  Frames: $(@($hashes[$i]).Count)"

            $hashProcessedCount++
            $hashPercent = 100.0 * $hashProcessedCount / $hashTotalCount

            Set-StepProgress `
                -Activity "Generating frame hashes" `
                -Status "$hashProcessedCount/$hashTotalCount files" `
                -PercentComplete $hashPercent

            Set-OverallProgress `
                -Stage "FrameHashes" `
                -PercentComplete $hashPercent `
                -Status "Frame hashes: $hashProcessedCount/$hashTotalCount"
        }
    }
    else {
        Set-OverallProgress `
            -Stage "FrameHashes" `
            -PercentComplete 100 `
            -Status "Frame hashes complete"
    }

    Complete-StepProgress -Activity "Generating frame hashes"

    $containedFilePlan = Get-DeepflyContainedFilePlan `
        -InputFiles $Files `
        -FrameHashes $hashes

    if ($containedFilePlan.SkippedFiles.Count -gt 0) {
        $originalFiles = @($Files)
        $originalAudioAvailable = @($audioAvailable)
        $originalAudioStreamIndices = @($audioStreamIndices)
        $originalHashes = $hashes

        foreach ($skippedFile in $containedFilePlan.SkippedFiles) {
            $skippedName = [IO.Path]::GetFileName(
                $originalFiles[$skippedFile.Index]
            )
            $containerName = [IO.Path]::GetFileName(
                $originalFiles[$skippedFile.PreviousIndex]
            )
            $nextName = [IO.Path]::GetFileName(
                $originalFiles[$skippedFile.NextIndex]
            )
            $containedEnd =
                $skippedFile.ContainedStart + $skippedFile.FrameCount - 1

            Write-Host ""
            Write-Host "Skipping contained Deepfly DF10 file: $skippedName"
            Write-Host (
                "All $($skippedFile.FrameCount) frames already exist in " +
                "$containerName at frames " +
                "$($skippedFile.ContainedStart)-$containedEnd."
            )
            Write-Host (
                "Bypass overlap with ${nextName}: " +
                "$($skippedFile.BypassOverlapLength) frame(s)."
            )

            $report.Add("")
            $report.Add(
                "Skipped contained Deepfly DF10 file: $skippedName"
            )
            $report.Add(
                "All $($skippedFile.FrameCount) frames already exist in " +
                "$containerName at frames " +
                "$($skippedFile.ContainedStart)-$containedEnd."
            )
            $report.Add(
                "Bypass overlap with ${nextName}: " +
                "$($skippedFile.BypassOverlapLength) frame(s)."
            )
        }

        $retainedFiles = New-Object System.Collections.Generic.List[string]
        $retainedAudioAvailable =
            New-Object System.Collections.Generic.List[bool]
        $retainedAudioStreamIndices =
            New-Object System.Collections.Generic.List[int]
        $retainedHashes = @{}

        foreach ($oldIndex in $containedFilePlan.RetainedIndices) {
            $newIndex = $retainedFiles.Count
            [void]$retainedFiles.Add($originalFiles[$oldIndex])
            [void]$retainedAudioAvailable.Add(
                [bool]$originalAudioAvailable[$oldIndex]
            )
            [void]$retainedAudioStreamIndices.Add(
                [int]$originalAudioStreamIndices[$oldIndex]
            )
            $retainedHashes[$newIndex] = @($originalHashes[$oldIndex])
        }

        $Files = [string[]]$retainedFiles.ToArray()
        $audioAvailable = $retainedAudioAvailable
        $audioStreamIndices = $retainedAudioStreamIndices
        $hashes = $retainedHashes
    }

    # ========================================================
    # Prepare H264 pieces
    # ========================================================

    $videoPieces =
        New-Object System.Collections.Generic.List[string]

    # --------------------------------------------------------
    # First video
    # --------------------------------------------------------

    $firstH264 = Join-Path $tempRoot "video_000.h264"

    Write-InfoBlank
    Write-Info "Extracting first video..."

    Run-FFmpeg @(
        "-y",
        "-i", $Files[0],
        "-map", "0:v:0",
        "-an",
        "-c:v", "copy",
        "-bsf:v", "h264_mp4toannexb",
        "-f", "h264",
        $firstH264
    )

    [void]$videoPieces.Add($firstH264)

    # ========================================================
    # Subsequent videos
    # ========================================================

    for ($i = 1; $i -lt $Files.Count; $i++) {

        $pairTotalCount = [Math]::Max(1, $Files.Count - 1)
        if ($i -eq 1) {
            Set-StepProgress `
                -Activity "Processing overlap and video pieces" `
                -Status "0/$pairTotalCount pairs" `
                -PercentComplete 0

            Set-OverallProgress `
                -Stage "PairProcessing" `
                -PercentComplete 0 `
                -Status "Pairs: 0/$pairTotalCount"
        }

        Write-InfoBlank
        Write-Info "=========================================="
        Write-Info "Processing:"
        Write-Info $Files[$i]
        Write-Info "=========================================="

        $previousHashes = $hashes[$i - 1]
        $currentHashes  = $hashes[$i]

        $overlapInfo =
            Find-OverlapWithEventFallback `
                $Files[$i - 1] `
                $Files[$i] `
                $previousHashes `
                $currentHashes

        $overlapCache[$i] = $overlapInfo

        $overlap = $overlapInfo.Result

        # ----------------------------------------------------
        # NO OVERLAP
        # ----------------------------------------------------

        if ($null -eq $overlap) {

            Write-Host ""
            Write-Host "WARNING: No overlap between:"
            Write-Host "  $([IO.Path]::GetFileName($Files[$i - 1]))"
            Write-Host "  $([IO.Path]::GetFileName($Files[$i]))"
            Write-Host "Appending entire current file."

            $report.Add("")
            $report.Add(
                "WARNING: No overlap between " +
                "$([IO.Path]::GetFileName($Files[$i - 1])) and " +
                "$([IO.Path]::GetFileName($Files[$i]))"
            )
            $report.Add(
                "Entire file was appended."
            )

            $wholeH264 = Join-Path $tempRoot (
                "nooverlap_{0:D3}.h264" -f $i
            )

            Run-FFmpeg @(
                "-y",
                "-i", $Files[$i],
                "-map", "0:v:0",
                "-an",
                "-c:v", "copy",
                "-bsf:v", "h264_mp4toannexb",
                "-f", "h264",
                $wholeH264
            )

            [void]$videoPieces.Add($wholeH264)

            $pairPercent = 100.0 * $i / $pairTotalCount
            Set-StepProgress `
                -Activity "Processing overlap and video pieces" `
                -Status "$i/$pairTotalCount pairs" `
                -PercentComplete $pairPercent
            Set-OverallProgress `
                -Stage "PairProcessing" `
                -PercentComplete $pairPercent `
                -Status "Pairs: $i/$pairTotalCount"

            continue
        }

        # ----------------------------------------------------
        # OVERLAP FOUND
        # ----------------------------------------------------

        Write-InfoBlank
        if ($overlapInfo.IsDeepflyOneGapOverlap) {
            Write-Info (
                "Deepfly DF10 REC-to-EVT overlap: " +
                "$($overlap.MatchedFrames) matching frames, " +
                "1 extra $($overlap.ExtraFrameIn) frame"
            )
        }
        elseif ($overlapInfo.IsDeepflyHandoff) {
            Write-Info (
                "Deepfly DF10 EVT-to-REC handoff overlap: " +
                "$($overlap.Length) frame(s)"
            )
        }
        elseif ($overlapInfo.IsEventOverlap) {
            Write-Info (
                "Event overlap: $($overlap.Length) frames " +
                "(REC tail is at start of EVT)"
            )
        }
        else {
            Write-Info "Overlap: $($overlap.Length) frames"
        }

        $report.Add("")
        if ($overlapInfo.IsDeepflyOneGapOverlap) {
            $report.Add(
                "Deepfly DF10 REC-to-EVT overlap between " +
                "$([IO.Path]::GetFileName($Files[$i - 1])) and " +
                "$([IO.Path]::GetFileName($Files[$i])): " +
                "$($overlap.MatchedFrames) matching frames, " +
                "1 extra $($overlap.ExtraFrameIn) frame"
            )
        }
        elseif ($overlapInfo.IsDeepflyHandoff) {
            $report.Add(
                "Deepfly DF10 handoff between " +
                "$([IO.Path]::GetFileName($Files[$i - 1])) and " +
                "$([IO.Path]::GetFileName($Files[$i])): " +
                "$($overlap.Length) duplicated boundary frame(s) removed"
            )
        }
        elseif ($overlapInfo.IsEventOverlap) {
            $report.Add(
                "Event overlap between " +
                "$([IO.Path]::GetFileName($Files[$i - 1])) and " +
                "$([IO.Path]::GetFileName($Files[$i])): " +
                "$($overlap.Length) frames " +
                "(REC tail is at start of EVT)"
            )
        }
        else {
            $report.Add(
                "Overlap between " +
                "$([IO.Path]::GetFileName($Files[$i - 1])) and " +
                "$([IO.Path]::GetFileName($Files[$i])): " +
                "$($overlap.Length) frames"
            )
        }

        $frameCacheKey = [IO.Path]::GetFullPath($Files[$i])
        if (-not $fileMetadataCache.ContainsKey($frameCacheKey)) {
            $fileMetadataCache[$frameCacheKey] =
                Get-FileMetadata $Files[$i]
        }

        $frames = @($fileMetadataCache[$frameCacheKey].Frames)

        Write-Info "Current file frames: $($frames.Count)"
        Write-Info "Overlap starts at current-file frame: $($overlap.BStart)"
        Write-Info "Overlap length: $($overlap.Length)"

        $firstNewFrame =
            $overlap.BStart + $overlap.Length

        Write-Info "First new frame: $firstNewFrame"

        # ----------------------------------------------------
        # Entire file is overlap
        # ----------------------------------------------------

        if ($firstNewFrame -ge $frames.Count) {

            Write-InfoBlank
            Write-Info "Entire current file is overlap."
            Write-Info "Nothing will be appended."

            $report.Add(
                "Entire file was overlap; nothing appended."
            )

            $pairPercent = 100.0 * $i / $pairTotalCount
            Set-StepProgress `
                -Activity "Processing overlap and video pieces" `
                -Status "$i/$pairTotalCount pairs" `
                -PercentComplete $pairPercent
            Set-OverallProgress `
                -Stage "PairProcessing" `
                -PercentComplete $pairPercent `
                -Status "Pairs: $i/$pairTotalCount"

            continue
        }

        # ----------------------------------------------------
        # Find next I-frame
        # ----------------------------------------------------

        $keyFrame = $null

        for ($f = $firstNewFrame;
             $f -lt $frames.Count;
             $f++) {

            if ($frames[$f].Type -eq "I") {
                $keyFrame = $f
                break
            }
        }

        if ($null -eq $keyFrame) {

            throw (
                "Could not find the next I-frame after " +
                "frame $firstNewFrame."
            )
        }

        $startTime =
            $frames[$firstNewFrame].Time

        $keyTime =
            $frames[$keyFrame].Time

        $transitionFrames =
            $keyFrame - $firstNewFrame

        Write-InfoBlank
        Write-Info "First new frame : $firstNewFrame"
        Write-Info "Next I-frame    : $keyFrame"
        Write-Info "Transition frames: $transitionFrames"
        Write-Info "Transition start: $startTime"
        Write-Info "Next I-frame    : $keyTime"

        # ----------------------------------------------------
        # Re-encode tiny transition
        # ----------------------------------------------------

        if ($transitionFrames -gt 0) {

            $transitionH264 = Join-Path $tempRoot (
                "transition_{0:D3}.h264" -f $i
            )

            $duration = $keyTime - $startTime

            Write-InfoBlank
            Write-Info (
                "Re-encoding only " +
                "$transitionFrames transition frames..."
            )

            Run-FFmpeg @(
                "-y",
                "-ss",
                $startTime.ToString(
                    [Globalization.CultureInfo]::InvariantCulture
                ),
                "-i",
                $Files[$i],
                "-t",
                $duration.ToString(
                    [Globalization.CultureInfo]::InvariantCulture
                ),
                "-an",
                "-c:v", "libx264",
                "-preset", "ultrafast",
                "-crf", "18",
                "-f", "h264",
                $transitionH264
            )

            [void]$videoPieces.Add($transitionH264)
        }

        # ----------------------------------------------------
        # Copy original video from next I-frame
        # ----------------------------------------------------

        $rest = Join-Path $tempRoot (
            "rest_{0:D3}.avi" -f $i
        )

        Write-InfoBlank
        Write-Info "Copying original H.264 from I-frame onward..."

        Run-FFmpeg @(
            "-y",
            "-ss",
            $keyTime.ToString(
                [Globalization.CultureInfo]::InvariantCulture
            ),
            "-i",
            $Files[$i],
            "-map", "0:v:0",
            "-an",
            "-c:v", "copy",
            $rest
        )

        $restH264 = Join-Path $tempRoot (
            "rest_{0:D3}.h264" -f $i
        )

        Run-FFmpeg @(
            "-y",
            "-i", $rest,
            "-an",
            "-c:v", "copy",
            "-bsf:v", "h264_mp4toannexb",
            "-f", "h264",
            $restH264
        )

        [void]$videoPieces.Add($restH264)

        $pairPercent = 100.0 * $i / $pairTotalCount
        Set-StepProgress `
            -Activity "Processing overlap and video pieces" `
            -Status "$i/$pairTotalCount pairs" `
            -PercentComplete $pairPercent
        Set-OverallProgress `
            -Stage "PairProcessing" `
            -PercentComplete $pairPercent `
            -Status "Pairs: $i/$pairTotalCount"
    }

    if ($Files.Count -le 1) {
        Set-OverallProgress `
            -Stage "PairProcessing" `
            -PercentComplete 100 `
            -Status "No pairs to process"
    }

    Complete-StepProgress -Activity "Processing overlap and video pieces"

    # ========================================================
    # Concatenate raw H264
    # ========================================================

    $combinedH264 =
        Join-Path $tempRoot "combined.h264"

    Write-Host ""
    Write-Host "Concatenating H.264 bitstreams..."

    Set-StepProgress `
        -Activity "Finalizing video" `
        -Status "Concatenating H.264" `
        -PercentComplete 20

    Set-OverallProgress `
        -Stage "VideoFinalize" `
        -PercentComplete 20 `
        -Status "Video finalize: concatenating bitstreams"

    Join-BinaryFiles -InputFiles @($videoPieces) -OutputFile $combinedH264

    Set-StepProgress `
        -Activity "Finalizing video" `
        -Status "Creating merged AVI" `
        -PercentComplete 55

    Set-OverallProgress `
        -Stage "VideoFinalize" `
        -PercentComplete 55 `
        -Status "Video finalize: creating merged AVI"

    # ========================================================
    # Create video-only merged AVI
    # ========================================================

    $firstDirectory = $OutputDirectory

    $output =
        Join-Path $firstDirectory (
            $firstName + "_merged.avi"
        )

    Write-Host ""
    Write-Host "Creating final video..."

    Run-FFmpeg @(
        "-y",
        "-fflags", "+genpts",
        "-r", $FrameRate,
        "-i", $combinedH264,
        "-c:v", "copy",
        $output
    )

    Set-StepProgress `
        -Activity "Finalizing video" `
        -Status "Video finalize complete" `
        -PercentComplete 100

    Set-OverallProgress `
        -Stage "VideoFinalize" `
        -PercentComplete 100 `
        -Status "Video finalize complete"

    Complete-StepProgress -Activity "Finalizing video"

# ========================================================
# AUDIO
#
# Each audio piece is forced to exactly match the duration
# of the corresponding video piece.
#
# This prevents cumulative A/V drift when many files are
# merged, and also handles files without audio by inserting
# silence.
# ========================================================

if ($ExcludeAudio) {

    Write-Host ""
    Write-Host "Audio excluded by request."
    $report.Add("")
    $report.Add("Audio was excluded by request.")

    Set-StepProgress `
        -Activity "Finalizing audio" `
        -Status "Audio excluded" `
        -PercentComplete 100

    Set-OverallProgress `
        -Stage "AudioFinalize" `
        -PercentComplete 100 `
        -Status "Audio excluded"

    Complete-StepProgress -Activity "Finalizing audio"
}
else {

Write-Host ""
Write-Host "Preparing audio..."

$audioProgressProcessed = 0
$audioProgressTotal = [Math]::Max(1, $Files.Count)

Set-StepProgress `
    -Activity "Finalizing audio" `
    -Status "Preparing segments: 0/$audioProgressTotal files" `
    -PercentComplete 0

Set-OverallProgress `
    -Stage "AudioFinalize" `
    -PercentComplete 0 `
    -Status "Audio finalize: preparing segments"

$audioParts =
    New-Object System.Collections.Generic.List[string]

$audioBoundaryRepairs =
    New-Object System.Collections.Generic.List[object]


# --------------------------------------------------------
# First video
# --------------------------------------------------------

$firstFrameCount =
    @($hashes[0]).Count

$firstVideoDuration =
    Get-VideoDurationFromFrames $firstFrameCount

$audio0 =
    Join-Path $tempRoot "audio_000.wav"

Create-AudioSegment `
    $Files[0] `
    $audio0 `
    0 `
    $firstVideoDuration `
    $audioAvailable[0] `
    $audioStreamIndices[0]

[void]$audioParts.Add($audio0)

$audioProgressProcessed++
$audioStagePercent = 70.0 * $audioProgressProcessed / $audioProgressTotal
Set-StepProgress `
    -Activity "Finalizing audio" `
    -Status "Preparing segments: $audioProgressProcessed/$audioProgressTotal files" `
    -PercentComplete $audioStagePercent
Set-OverallProgress `
    -Stage "AudioFinalize" `
    -PercentComplete $audioStagePercent `
    -Status "Audio finalize: preparing segments"

# --------------------------------------------------------
# Subsequent videos
# --------------------------------------------------------

for ($i = 1; $i -lt $Files.Count; $i++) {

    $currentFrameCount =
        @($hashes[$i]).Count

    $previousHashes =
        $hashes[$i - 1]

    $currentHashes =
        $hashes[$i]

    $overlapInfo = $overlapCache[$i]
    if ($null -eq $overlapInfo) {
        $overlapInfo =
            Find-OverlapWithEventFallback `
                $Files[$i - 1] `
                $Files[$i] `
                $previousHashes `
                $currentHashes

        $overlapCache[$i] = $overlapInfo
    }

    $overlap = $overlapInfo.Result

    # ----------------------------------------------------
    # Determine how many video frames are actually added
    # ----------------------------------------------------

    if ($null -eq $overlap) {

        # Entire file is appended
        $firstNewFrame = 0

    }
    else {

        $firstNewFrame =
            $overlap.BStart + $overlap.Length
    }

    $newFrameCount =
        $currentFrameCount - $firstNewFrame

    # Entire file was already present
    if ($newFrameCount -le 0) {

        Write-Info (
            "Audio: " +
            [IO.Path]::GetFileName($Files[$i]) +
            " contributes no video frames."
        )

        $audioProgressProcessed++
        $audioStagePercent = 70.0 * $audioProgressProcessed / $audioProgressTotal
        Set-StepProgress `
            -Activity "Finalizing audio" `
            -Status "Preparing segments: $audioProgressProcessed/$audioProgressTotal files" `
            -PercentComplete $audioStagePercent
        Set-OverallProgress `
            -Stage "AudioFinalize" `
            -PercentComplete $audioStagePercent `
            -Status "Audio finalize: preparing segments"

        continue
    }

    # This is the exact duration of the video contribution
    $videoSegmentDuration =
        Get-VideoDurationFromFrames $newFrameCount

    # ----------------------------------------------------
    # Audio starting point
    # ----------------------------------------------------

    $audioStart = 0.0

    if ($firstNewFrame -gt 0) {

        $frameCacheKey = [IO.Path]::GetFullPath($Files[$i])
        if (-not $fileMetadataCache.ContainsKey($frameCacheKey)) {
            $fileMetadataCache[$frameCacheKey] =
                Get-FileMetadata $Files[$i]
        }

        $frames =
            @($fileMetadataCache[$frameCacheKey].Frames)

        if ($firstNewFrame -ge $frames.Count) {
            $audioProgressProcessed++
            $audioStagePercent = 70.0 * $audioProgressProcessed / $audioProgressTotal
            Set-StepProgress `
                -Activity "Finalizing audio" `
                -Status "Preparing segments: $audioProgressProcessed/$audioProgressTotal files" `
                -PercentComplete $audioStagePercent
            Set-OverallProgress `
                -Stage "AudioFinalize" `
                -PercentComplete $audioStagePercent `
                -Status "Audio finalize: preparing segments"

            continue
        }

        $audioStart =
            $frames[$firstNewFrame].Time
    }

    $audioPart =
        Join-Path $tempRoot (
            "audio_{0:D3}.wav" -f $i
        )

    Create-AudioSegment `
        $Files[$i] `
        $audioPart `
        $audioStart `
        $videoSegmentDuration `
        $audioAvailable[$i] `
        $audioStreamIndices[$i]

    [void]$audioParts.Add($audioPart)

    $audioProgressProcessed++
    $audioStagePercent = 70.0 * $audioProgressProcessed / $audioProgressTotal
    Set-StepProgress `
        -Activity "Finalizing audio" `
        -Status "Preparing segments: $audioProgressProcessed/$audioProgressTotal files" `
        -PercentComplete $audioStagePercent
    Set-OverallProgress `
        -Stage "AudioFinalize" `
        -PercentComplete $audioStagePercent `
        -Status "Audio finalize: preparing segments"
}

# --------------------------------------------------------
# Concatenate audio
# --------------------------------------------------------

if ($audioParts.Count -gt 0) {

    $audioList =
        Join-Path $tempRoot "audio_concat.txt"

    $audioLines =
        $audioParts | ForEach-Object {
            "file '" + $_.Replace("'", "'\''") + "'"
        }

    # IMPORTANT:
    # Write UTF-8 WITHOUT BOM.
    #
    # FFmpeg's concat demuxer does not like the BOM that
    # PowerShell's normal UTF8 encoding can add.

    $utf8NoBom =
        New-Object System.Text.UTF8Encoding($false)

    [System.IO.File]::WriteAllLines(
        $audioList,
        [string[]]$audioLines,
        $utf8NoBom
    )

    $mergedAudio =
        Join-Path $tempRoot "merged_audio.wav"

    Write-Host ""
    Write-Host "Concatenating audio..."

    Set-StepProgress `
        -Activity "Finalizing audio" `
        -Status "Concatenating audio" `
        -PercentComplete 85

    Set-OverallProgress `
        -Stage "AudioFinalize" `
        -PercentComplete 85 `
        -Status "Audio finalize: concatenating"

    Run-FFmpeg @(
        "-y",
        "-f", "concat",
        "-safe", "0",
        "-i", $audioList,
        "-c:a", "pcm_s16le",
        $mergedAudio
    )

    # ----------------------------------------------------
    # Mux audio into final AVI
    # ----------------------------------------------------

    $finalOutput =
        Join-Path $firstDirectory (
            $firstName + "_merged_with_audio.avi"
        )

    Write-Host ""
    Write-Host "Muxing video and audio..."

    Set-StepProgress `
        -Activity "Finalizing audio" `
        -Status "Muxing audio into final AVI" `
        -PercentComplete 95

    Set-OverallProgress `
        -Stage "AudioFinalize" `
        -PercentComplete 95 `
        -Status "Audio finalize: muxing"

    Run-FFmpeg @(
        "-y",
        "-i", $output,
        "-i", $mergedAudio,
        "-map", "0:v:0",
        "-map", "1:a:0",
        "-map_metadata", "-1",
        "-map_chapters", "-1",
        "-sn",
        "-dn",
        "-c:v", "copy",
        "-c:a", "pcm_s16le",
        $finalOutput
    )

    # Only replace the old video after the mux succeeded
    Remove-Item -LiteralPath $output -Force

    Rename-Item `
        -LiteralPath $finalOutput `
        -NewName ([IO.Path]::GetFileName($output))

    $report.Add("")
    $report.Add("Audio was added successfully.")
    $report.Add(
        "Audio segments were individually padded/trimmed to match video."
    )
    if ($audioBoundaryRepairs.Count -gt 0) {
        $report.Add(
            "Short audio boundary gaps repaired: " +
            $audioBoundaryRepairs.Count
        )
        foreach ($repair in $audioBoundaryRepairs) {
            $report.Add(
                "Audio repair: $($repair.File), gap=" +
                $repair.GapSeconds.ToString(
                    "0.000",
                    [Globalization.CultureInfo]::InvariantCulture
                ) +
                "s, tail=" +
                $repair.TailSeconds.ToString(
                    "0.000",
                    [Globalization.CultureInfo]::InvariantCulture
                ) +
                "s, compensation=" +
                $repair.CompensationSeconds.ToString(
                    "0.000",
                    [Globalization.CultureInfo]::InvariantCulture
                ) +
                "s, tempo=" +
                $repair.Tempo.ToString(
                    "0.000000",
                    [Globalization.CultureInfo]::InvariantCulture
                )
            )
        }
    }

    Set-StepProgress `
        -Activity "Finalizing audio" `
        -Status "Audio finalize complete" `
        -PercentComplete 100

    Set-OverallProgress `
        -Stage "AudioFinalize" `
        -PercentComplete 100 `
        -Status "Audio finalize complete"

    Complete-StepProgress -Activity "Finalizing audio"

    Write-Host ""
    Write-Host "Audio successfully added."
}
else {

    Write-Host ""
    Write-Host "No audio segments were created."

    $report.Add("")
    $report.Add("No audio segments were created.")

    Set-StepProgress `
        -Activity "Finalizing audio" `
        -Status "No audio segments were created" `
        -PercentComplete 100

    Set-OverallProgress `
        -Stage "AudioFinalize" `
        -PercentComplete 100 `
        -Status "Audio finalize complete"

    Complete-StepProgress -Activity "Finalizing audio"
}
}
    # ========================================================
    # Final report
    # ========================================================

    $report.Add("")
    $report.Add("Output:")
    $report.Add($output)
    $report.Add("")
    $report.Add("Completed successfully.")

    Set-Content `
        -LiteralPath $resultFile `
        -Value $report `
        -Encoding UTF8

    Write-Host ""
    Write-Host "=========================================="
    Write-Host "Done:"
    Write-Host $output
    Write-Host ""
    Write-Host "Report:"
    Write-Host $resultFile
    Write-Host "=========================================="
    Write-Host ""

    $mergeSucceeded = $true

    Set-OverallProgress `
        -Stage "Setup" `
        -PercentComplete 100 `
        -Status "Merge completed successfully"

    Complete-AllProgress

    Write-Host "Press Enter to open the target folder and select the merged video."
    Write-Host "Press Esc to finish."

    try {
        $key = [Console]::ReadKey($true)

        if ($key.Key -eq [ConsoleKey]::Enter) {
            Start-Process `
                -FilePath "explorer.exe" `
                -ArgumentList "/select,`"$output`""
        }
    }
    catch {
        Write-Host "Could not open the target folder."
    }
}
catch {

    $report.Add("")
    $report.Add("FAILED:")
    $report.Add($_.Exception.Message)

    Set-Content `
        -LiteralPath $resultFile `
        -Value $report `
        -Encoding UTF8

    Write-Host ""
    Write-Host "FAILED:"
    Write-Host $_.Exception.Message
    Write-Host ""

    exit 1
}
finally {

    Complete-AllProgress

    if (-not [string]::IsNullOrWhiteSpace([string]$tempRoot)) {
        Remove-Item `
            -LiteralPath $tempRoot `
            -Recurse `
            -Force `
            -ErrorAction SilentlyContinue
    }

    if (
        $usedTempFallback -and
        -not [string]::IsNullOrWhiteSpace([string]$tempBaseDirectory) -and
        (Test-Path -LiteralPath $tempBaseDirectory -PathType Container)
    ) {
        try {
            $remainingItems = @(
                Get-ChildItem -LiteralPath $tempBaseDirectory -Force -ErrorAction Stop
            )

            if ($remainingItems.Count -eq 0) {
                Remove-Item -LiteralPath $tempBaseDirectory -Force -ErrorAction Stop
            }
        }
        catch {
            # Best-effort cleanup only; do not fail the script if this cannot be removed.
        }
    }

    if (-not $mergeSucceeded) {
        Wait-ForUserExit "Press Enter to close."
    }
}

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
# Helpers
# ============================================================

function Run-FFmpeg {
    param(
        [string[]]$Arguments
    )

    if (-not $SuppressFFmpegConsoleOutput) {
        $previousErrorActionPreference = $ErrorActionPreference

        try {
            $ErrorActionPreference = "Continue"
            & $ffmpeg @Arguments
            $exitCode = $LASTEXITCODE
        }
        finally {
            $ErrorActionPreference = $previousErrorActionPreference
        }

        if ($exitCode -ne 0) {
            throw "FFmpeg failed with exit code $exitCode"
        }

        return
    }

    $quietArguments = @(
        "-hide_banner",
        "-loglevel", "error",
        "-nostats"
    ) + @($Arguments)

    $stdoutLog = Join-Path $env:TEMP (
        "dashcam_ffmpeg_stdout_" + [guid]::NewGuid().ToString("N") + ".log"
    )
    $stderrLog = Join-Path $env:TEMP (
        "dashcam_ffmpeg_stderr_" + [guid]::NewGuid().ToString("N") + ".log"
    )

    $commandText = ($Arguments -join " ")
    $previousErrorActionPreference = $ErrorActionPreference

    try {
        try {
            $ErrorActionPreference = "Continue"
            & $ffmpeg @quietArguments 1>$stdoutLog 2>$stderrLog
            $exitCode = $LASTEXITCODE
        }
        finally {
            $ErrorActionPreference = $previousErrorActionPreference
        }

        if ($exitCode -ne 0) {
            $stderrLines = @()
            $stdoutLines = @()

            if (Test-Path -LiteralPath $stderrLog -PathType Leaf) {
                $stderrLines = @(
                    Get-Content -LiteralPath $stderrLog -ErrorAction SilentlyContinue
                )
            }

            if (Test-Path -LiteralPath $stdoutLog -PathType Leaf) {
                $stdoutLines = @(
                    Get-Content -LiteralPath $stdoutLog -ErrorAction SilentlyContinue
                )
            }

            $lines = @(
                @($stderrLines) + @($stdoutLines) |
                    ForEach-Object { [string]$_ } |
                    Where-Object {
                        -not [string]::IsNullOrWhiteSpace($_)
                    }
            )

            $detailText = ($lines -join [Environment]::NewLine)
            $knownCorruptAudioIssue = (
                $detailText -match "mp3float" -or
                $detailText -match "Header missing" -or
                $detailText -match "Invalid data found when processing input" -or
                $detailText -match "Error while decoding stream"
            )

            $outputCandidate = $null
            if ($Arguments.Count -gt 0) {
                $lastArgument = [string]$Arguments[$Arguments.Count - 1]
                if (-not [string]::IsNullOrWhiteSpace($lastArgument) -and
                    $lastArgument -ne "-") {
                    $outputCandidate = $lastArgument
                }
            }

            $hasUsableOutput = $false
            if (-not [string]::IsNullOrWhiteSpace($outputCandidate)) {
                try {
                    if (Test-Path -LiteralPath $outputCandidate -PathType Leaf) {
                        $hasUsableOutput = (
                            (Get-Item -LiteralPath $outputCandidate).Length -gt 0
                        )
                    }
                }
                catch {
                    $hasUsableOutput = $false
                }
            }

            if ($knownCorruptAudioIssue -and $hasUsableOutput) {
                Write-Host ""
                Write-Host (
                    "WARNING: FFmpeg reported corrupt audio packets, " +
                    "but usable output was produced. Continuing."
                )
                return
            }

            if ($lines.Count -gt 0) {
                throw (
                    "FFmpeg failed with exit code $exitCode" +
                    [Environment]::NewLine +
                    "Command: $commandText" +
                    [Environment]::NewLine +
                    ($lines -join [Environment]::NewLine)
                )
            }

            throw (
                "FFmpeg failed with exit code $exitCode" +
                [Environment]::NewLine +
                "Command: $commandText"
            )
        }
    }
    finally {
        Remove-Item -LiteralPath $stdoutLog -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath $stderrLog -Force -ErrorAction SilentlyContinue
    }
}

function Invoke-FFprobe {
    param(
        [string[]]$Arguments
    )

    $previousErrorActionPreference = $ErrorActionPreference

    try {
        $ErrorActionPreference = "Continue"

        # Some dashcam AVIs contain a broken/empty MP3 stream. FFprobe can
        # still return valid information for the requested stream (especially
        # video) but exits non-zero because it encountered that unrelated
        # broken stream. Do not treat that probe warning as a fatal error.
        $result = @(& $ffprobe @Arguments 2>$null)
    }
    finally {
        $ErrorActionPreference = $previousErrorActionPreference
    }

    return $result
}

function Get-DetectedVideoFrameRate {
    param(
        [string]$File
    )

    $rateText = (
        @(
            Invoke-FFprobe @(
                "-v", "error",
                "-select_streams", "v:0",
                "-show_entries", "stream=avg_frame_rate",
                "-of", "default=nw=1:nk=1",
                $File
            )
        ) -join ""
    ).Trim()

    $rateMatch = [regex]::Match(
        $rateText,
        '^([0-9]+(?:\.[0-9]+)?)/([0-9]+(?:\.[0-9]+)?)$'
    )

    if (-not $rateMatch.Success) {
        return $null
    }

    $numerator = [double]::Parse(
        $rateMatch.Groups[1].Value,
        [Globalization.CultureInfo]::InvariantCulture
    )
    $denominator = [double]::Parse(
        $rateMatch.Groups[2].Value,
        [Globalization.CultureInfo]::InvariantCulture
    )

    if ($numerator -le 0 -or $denominator -le 0) {
        return $null
    }

    return $numerator / $denominator
}

function Test-QuickVideoValidity {
    param(
        [string]$File,
        [double]$DecodeSeconds
    )

    $videoStream = @(
        Invoke-FFprobe @(
            "-v", "error",
            "-select_streams", "v:0",
            "-show_entries", "stream=codec_name",
            "-of", "default=nw=1:nk=1",
            $File
        )
    )

    $videoCodec = ($videoStream -join "").Trim()
    if ([string]::IsNullOrWhiteSpace($videoCodec)) {
        return [PSCustomObject]@{
            IsValid = $false
            Stage = "header"
            Detail = "no readable video stream"
        }
    }

    $secondsText = $DecodeSeconds.ToString(
        "0.###",
        [Globalization.CultureInfo]::InvariantCulture
    )

    $quickArguments = @(
        "-hide_banner",
        "-loglevel", "error",
        "-nostats",
        "-t", $secondsText,
        "-i", $File,
        "-map", "0:v:0",
        "-f", "null",
        "-"
    )

    $previousErrorActionPreference = $ErrorActionPreference
    try {
        $ErrorActionPreference = "Continue"
        & $ffmpeg @quickArguments 1>$null 2>$null
        $decodeExitCode = $LASTEXITCODE
    }
    finally {
        $ErrorActionPreference = $previousErrorActionPreference
    }

    if ($decodeExitCode -ne 0) {
        return [PSCustomObject]@{
            IsValid = $false
            Stage = "decode${secondsText}s"
            Detail = "ffmpeg decode failed"
        }
    }

    return [PSCustomObject]@{
        IsValid = $true
        Stage = "ok"
        Detail = ""
    }
}

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

function Write-Info {
    param(
        [string]$Message
    )

    if ($MinimalConsoleOutput) {
        return
    }

    Write-Host $Message
}

function Write-InfoBlank {
    if ($MinimalConsoleOutput) {
        return
    }

    Write-Host ""
}

function Format-ByteSize {
    param(
        [double]$Bytes
    )

    $units = @("B", "KB", "MB", "GB", "TB", "PB")
    $size = [Math]::Max(0.0, $Bytes)
    $unitIndex = 0

    while ($size -ge 1024.0 -and $unitIndex -lt $units.Count - 1) {
        $size /= 1024.0
        $unitIndex++
    }

    return (
        $size.ToString("0.##", [Globalization.CultureInfo]::InvariantCulture) +
        " " +
        $units[$unitIndex]
    )
}

function Get-DriveSpaceSnapshot {
    param(
        [string]$Path
    )

    $fullPath = [IO.Path]::GetFullPath($Path)
    $root = [IO.Path]::GetPathRoot($fullPath)

    if ([string]::IsNullOrWhiteSpace($root)) {
        throw "Could not determine drive root for path: $Path"
    }

    try {
        $driveInfo = [System.IO.DriveInfo]::new($root)
    }
    catch {
        throw "Could not read drive information for path: $Path"
    }

    if (-not $driveInfo.IsReady) {
        throw "Drive is not ready for path: $Path"
    }

    return [PSCustomObject]@{
        Root = $driveInfo.Name.TrimEnd('\\')
        FreeBytes = [int64]$driveInfo.AvailableFreeSpace
    }
}

function Get-MergeStorageEstimate {
    param(
        [string[]]$InputFiles,
        [bool]$IncludeAudio
    )

    $totalInputBytes = [int64]0
    $largestInputBytes = [int64]0
    $totalDurationSeconds = 0.0

    foreach ($file in $InputFiles) {
        $item = Get-Item -LiteralPath $file
        $fileBytes = [int64]$item.Length
        $totalInputBytes += $fileBytes

        if ($fileBytes -gt $largestInputBytes) {
            $largestInputBytes = $fileBytes
        }

        $durationText = (
            @(
                Invoke-FFprobe @(
                    "-v", "error",
                    "-show_entries", "format=duration",
                    "-of", "default=nw=1:nk=1",
                    $file
                )
            ) -join ""
        ).Trim()

        $durationSeconds = 0.0
        $durationParsed = [double]::TryParse(
            $durationText,
            [Globalization.NumberStyles]::Float,
            [Globalization.CultureInfo]::InvariantCulture,
            [ref]$durationSeconds
        )

        if ($durationParsed -and $durationSeconds -gt 0) {
            $totalDurationSeconds += $durationSeconds
        }
    }

    $estimatedVideoBytes = [int64][Math]::Ceiling($totalInputBytes * 1.05)
    $estimatedPcmBytes = [int64]0

    if ($IncludeAudio) {
        if ($totalDurationSeconds -gt 0) {
            $estimatedPcmBytes = [int64][Math]::Ceiling(
                $totalDurationSeconds * 16000.0 * 2.0
            )
        }
        else {
            # Fallback when durations cannot be probed.
            $estimatedPcmBytes = [int64][Math]::Ceiling($totalInputBytes * 0.25)
        }
    }

    $estimatedFinalOutputBytes = $estimatedVideoBytes
    if ($IncludeAudio) {
        $estimatedFinalOutputBytes += $estimatedPcmBytes
    }

    $targetPeakBytes = $estimatedFinalOutputBytes
    if ($IncludeAudio) {
        # Video-only AVI and final AVI coexist briefly during mux stage.
        $targetPeakBytes += $estimatedVideoBytes
    }

    $tempPeakBytes =
        (2 * $estimatedVideoBytes) +
        $largestInputBytes +
        (2 * $estimatedPcmBytes)

    $safetyBufferBytes = [int64](256MB)
    $requiredTargetBytes = [int64][Math]::Ceiling(
        ($targetPeakBytes * 1.10) + $safetyBufferBytes
    )
    $requiredTempBytes = [int64][Math]::Ceiling(
        ($tempPeakBytes * 1.10) + $safetyBufferBytes
    )

    return [PSCustomObject]@{
        TotalInputBytes = $totalInputBytes
        TotalDurationSeconds = $totalDurationSeconds
        EstimatedFinalOutputBytes = $estimatedFinalOutputBytes
        EstimatedPcmBytes = $estimatedPcmBytes
        RequiredTargetBytes = $requiredTargetBytes
        RequiredTempBytes = $requiredTempBytes
    }
}

function Assert-MergeFreeSpace {
    param(
        [string[]]$InputFiles,
        [string]$OutputDirectory,
        [string]$TempDirectory,
        [bool]$IncludeAudio
    )

    $estimate = Get-MergeStorageEstimate `
        -InputFiles $InputFiles `
        -IncludeAudio $IncludeAudio

    $targetDrive = Get-DriveSpaceSnapshot -Path $OutputDirectory
    $tempDrive = Get-DriveSpaceSnapshot -Path $TempDirectory

    Write-Host ""
    Write-Host "Storage pre-check:"
    Write-Host (
        "- Estimated final output: " +
        (Format-ByteSize $estimate.EstimatedFinalOutputBytes)
    )
    if ($IncludeAudio) {
        Write-Host (
            "- Estimated PCM audio footprint: " +
            (Format-ByteSize $estimate.EstimatedPcmBytes)
        )
    }
    Write-Host (
        "- Required free space on output drive (" +
        $targetDrive.Root +
        "): " +
        (Format-ByteSize $estimate.RequiredTargetBytes) +
        " (available " +
        (Format-ByteSize $targetDrive.FreeBytes) +
        ")"
    )
    Write-Host (
        "- Required free space on temp drive (" +
        $tempDrive.Root +
        "): " +
        (Format-ByteSize $estimate.RequiredTempBytes) +
        " (available " +
        (Format-ByteSize $tempDrive.FreeBytes) +
        ")"
    )

    if ($targetDrive.Root -eq $tempDrive.Root) {
        $combinedRequiredBytes =
            $estimate.RequiredTargetBytes + $estimate.RequiredTempBytes

        if ($targetDrive.FreeBytes -lt $combinedRequiredBytes) {
            $missingBytes = $combinedRequiredBytes - $targetDrive.FreeBytes
            throw (
                "Not enough free disk space to continue. " +
                "Output and temp folders are on the same drive (" +
                $targetDrive.Root +
                "). Required " +
                (Format-ByteSize $combinedRequiredBytes) +
                ", available " +
                (Format-ByteSize $targetDrive.FreeBytes) +
                ", short by " +
                (Format-ByteSize $missingBytes) +
                "."
            )
        }

        return
    }

    if ($targetDrive.FreeBytes -lt $estimate.RequiredTargetBytes) {
        $missingBytes = $estimate.RequiredTargetBytes - $targetDrive.FreeBytes
        throw (
            "Not enough free disk space on output drive " +
            $targetDrive.Root +
            ". Required " +
            (Format-ByteSize $estimate.RequiredTargetBytes) +
            ", available " +
            (Format-ByteSize $targetDrive.FreeBytes) +
            ", short by " +
            (Format-ByteSize $missingBytes) +
            "."
        )
    }

    if ($tempDrive.FreeBytes -lt $estimate.RequiredTempBytes) {
        $missingBytes = $estimate.RequiredTempBytes - $tempDrive.FreeBytes
        throw (
            "Not enough free disk space on temp drive " +
            $tempDrive.Root +
            ". Required " +
            (Format-ByteSize $estimate.RequiredTempBytes) +
            ", available " +
            (Format-ByteSize $tempDrive.FreeBytes) +
            ", short by " +
            (Format-ByteSize $missingBytes) +
            "."
        )
    }
}

function Join-BinaryFiles {
    param(
        [string[]]$InputFiles,
        [string]$OutputFile
    )

    if ($null -eq $InputFiles -or $InputFiles.Count -eq 0) {
        throw "No input files were provided for binary concatenation."
    }

    $bufferSize = 4MB
    $buffer = New-Object byte[] $bufferSize

    $outputStream = [System.IO.File]::Open(
        $OutputFile,
        [System.IO.FileMode]::Create,
        [System.IO.FileAccess]::Write,
        [System.IO.FileShare]::None
    )

    try {
        foreach ($inputFile in $InputFiles) {
            $inputStream = [System.IO.File]::Open(
                $inputFile,
                [System.IO.FileMode]::Open,
                [System.IO.FileAccess]::Read,
                [System.IO.FileShare]::Read
            )

            try {
                while ($true) {
                    $readCount = $inputStream.Read($buffer, 0, $buffer.Length)

                    if ($readCount -le 0) {
                        break
                    }

                    $outputStream.Write($buffer, 0, $readCount)
                }
            }
            finally {
                $inputStream.Dispose()
            }
        }
    }
    finally {
        $outputStream.Dispose()
    }
}

function Get-VideoFrames {
    param(
        [string]$File
    )

    $lines = @(
        Invoke-FFprobe @(
            "-v", "quiet",
            "-select_streams", "v:0",
            "-show_entries", "frame=best_effort_timestamp_time,pict_type",
            "-of", "csv=p=0",
            $File
        )
    )

    $frames = New-Object System.Collections.Generic.List[object]

    foreach ($line in $lines) {

        if ([string]::IsNullOrWhiteSpace($line)) {
            continue
        }

        $parts = ([string]$line) -split ","

        if ($parts.Count -lt 2) {
            continue
        }

        try {
            $time = [double]::Parse(
                $parts[0].Trim(),
                [Globalization.CultureInfo]::InvariantCulture
            )

            $type = $parts[1].Trim()

            [void]$frames.Add(
                [PSCustomObject]@{
                    Time = $time
                    Type = $type
                }
            )
        }
        catch {
            continue
        }
    }

    return $frames.ToArray()
}

function Get-FileMetadata {
    param(
        [string]$File
    )

    $probeOutput = @(
        Invoke-FFprobe @(
            "-v", "quiet",
            "-select_streams", "v:0,a",
            "-show_entries", "stream=index,codec_name,codec_type:frame=best_effort_timestamp_time,pict_type",
            "-of", "json",
            $File
        )
    )

    $pcmStreamIndex = -1
    $frames = $null

    if ($probeOutput.Count -gt 0) {
        $jsonText = ($probeOutput -join [Environment]::NewLine).Trim()

        if (-not [string]::IsNullOrWhiteSpace($jsonText)) {
            try {
                $metadata = $jsonText | ConvertFrom-Json -ErrorAction Stop

                if ($null -ne $metadata.streams) {
                    foreach ($stream in @($metadata.streams)) {
                        if ($null -eq $stream.codec_type -or
                            $null -eq $stream.codec_name) {
                            continue
                        }

                        if ($stream.codec_type -eq "audio" -and
                            $stream.codec_name.ToLowerInvariant() -eq "pcm_s16le") {

                            try {
                                $pcmStreamIndex = [int]$stream.index
                                break
                            }
                            catch {
                                continue
                            }
                        }
                    }
                }

                $frameList = New-Object System.Collections.Generic.List[object]

                if ($null -ne $metadata.frames) {
                    foreach ($frame in @($metadata.frames)) {
                        if ($null -eq $frame.best_effort_timestamp_time -or
                            $null -eq $frame.pict_type) {
                            continue
                        }

                        try {
                            $time = [double]::Parse(
                                [string]$frame.best_effort_timestamp_time,
                                [Globalization.CultureInfo]::InvariantCulture
                            )

                            [void]$frameList.Add(
                                [PSCustomObject]@{
                                    Time = $time
                                    Type = [string]$frame.pict_type
                                }
                            )
                        }
                        catch {
                            continue
                        }
                    }
                }

                if ($frameList.Count -gt 0) {
                    $frames = $frameList.ToArray()
                }
            }
            catch {
            }
        }
    }

    if ($null -eq $frames) {
        $frames = @(Get-VideoFrames $File)
    }

    if ($pcmStreamIndex -lt 0) {
        $pcmStreamIndex = Get-PCMStreamIndex $File
    }

    return [PSCustomObject]@{
        PcmStreamIndex = $pcmStreamIndex
        Frames = $frames
    }
}

function Get-FileMetadataParallel {
    param(
        [string[]]$InputFiles,
        [int]$WorkerCount,
        [string]$FfprobePath,
        [string]$ProgressStage = "",
        [string]$ProgressActivity = ""
    )

    $files = @($InputFiles)
    $results = @{}

    if ($files.Count -eq 0) {
        return $results
    }

    $workerLimit = [Math]::Max(
        1,
        [Math]::Min($WorkerCount, $files.Count)
    )

    $completedCount = 0

    $activeJobs = New-Object System.Collections.ArrayList
    $nextIndex = 0

    try {
        while ($nextIndex -lt $files.Count -or $activeJobs.Count -gt 0) {

            while (
                $nextIndex -lt $files.Count -and
                $activeJobs.Count -lt $workerLimit
            ) {

                $index = $nextIndex
                $file = $files[$index]

                $job = Start-Job -ScriptBlock {
                    param(
                        [string]$ffprobeExe,
                        [string]$filePath,
                        [int]$fileIndex
                    )

                    function Invoke-LocalFFprobe {
                        param(
                            [string[]]$Arguments
                        )

                        return @(& $ffprobeExe @Arguments 2>$null)
                    }

                    function Get-LocalVideoFrames {
                        param(
                            [string]$File
                        )

                        $lines = @(
                            Invoke-LocalFFprobe @(
                                "-v", "quiet",
                                "-select_streams", "v:0",
                                "-show_entries", "frame=best_effort_timestamp_time,pict_type",
                                "-of", "csv=p=0",
                                $File
                            )
                        )

                        $frames = New-Object System.Collections.Generic.List[object]

                        foreach ($line in $lines) {
                            if ([string]::IsNullOrWhiteSpace($line)) {
                                continue
                            }

                            $parts = ([string]$line) -split ","

                            if ($parts.Count -lt 2) {
                                continue
                            }

                            try {
                                $time = [double]::Parse(
                                    $parts[0].Trim(),
                                    [Globalization.CultureInfo]::InvariantCulture
                                )

                                [void]$frames.Add(
                                    [PSCustomObject]@{
                                        Time = $time
                                        Type = $parts[1].Trim()
                                    }
                                )
                            }
                            catch {
                                continue
                            }
                        }

                        return $frames.ToArray()
                    }

                    function Get-LocalPCMStreamIndex {
                        param(
                            [string]$File
                        )

                        $result = @(
                            Invoke-LocalFFprobe @(
                                "-v", "quiet",
                                "-select_streams", "a",
                                "-show_entries", "stream=index,codec_name",
                                "-of", "csv=p=0",
                                $File
                            )
                        )

                        foreach ($line in $result) {
                            if ([string]::IsNullOrWhiteSpace([string]$line)) {
                                continue
                            }

                            $parts = ([string]$line) -split ","

                            if ($parts.Count -lt 2) {
                                continue
                            }

                            if ($parts[1].Trim().ToLowerInvariant() -eq "pcm_s16le") {
                                try {
                                    return [int]$parts[0].Trim()
                                }
                                catch {
                                    continue
                                }
                            }
                        }

                        return -1
                    }

                    try {
                        $probeOutput = @(
                            Invoke-LocalFFprobe @(
                                "-v", "quiet",
                                "-select_streams", "v:0,a",
                                "-show_entries", "stream=index,codec_name,codec_type:frame=best_effort_timestamp_time,pict_type",
                                "-of", "json",
                                $filePath
                            )
                        )

                        $pcmStreamIndex = -1
                        $frames = $null

                        if ($probeOutput.Count -gt 0) {
                            $jsonText = ($probeOutput -join [Environment]::NewLine).Trim()

                            if (-not [string]::IsNullOrWhiteSpace($jsonText)) {
                                try {
                                    $metadata = $jsonText | ConvertFrom-Json -ErrorAction Stop

                                    if ($null -ne $metadata.streams) {
                                        foreach ($stream in @($metadata.streams)) {
                                            if ($null -eq $stream.codec_type -or
                                                $null -eq $stream.codec_name) {
                                                continue
                                            }

                                            if ($stream.codec_type -eq "audio" -and
                                                $stream.codec_name.ToLowerInvariant() -eq "pcm_s16le") {

                                                try {
                                                    $pcmStreamIndex = [int]$stream.index
                                                    break
                                                }
                                                catch {
                                                    continue
                                                }
                                            }
                                        }
                                    }

                                    $frameList =
                                        New-Object System.Collections.Generic.List[object]

                                    if ($null -ne $metadata.frames) {
                                        foreach ($frame in @($metadata.frames)) {
                                            if ($null -eq $frame.best_effort_timestamp_time -or
                                                $null -eq $frame.pict_type) {
                                                continue
                                            }

                                            try {
                                                $time = [double]::Parse(
                                                    [string]$frame.best_effort_timestamp_time,
                                                    [Globalization.CultureInfo]::InvariantCulture
                                                )

                                                [void]$frameList.Add(
                                                    [PSCustomObject]@{
                                                        Time = $time
                                                        Type = [string]$frame.pict_type
                                                    }
                                                )
                                            }
                                            catch {
                                                continue
                                            }
                                        }
                                    }

                                    if ($frameList.Count -gt 0) {
                                        $frames = $frameList.ToArray()
                                    }
                                }
                                catch {
                                }
                            }
                        }

                        if ($null -eq $frames) {
                            $frames = @(Get-LocalVideoFrames $filePath)
                        }

                        if ($pcmStreamIndex -lt 0) {
                            $pcmStreamIndex = Get-LocalPCMStreamIndex $filePath
                        }

                        return [PSCustomObject]@{
                            Index = $fileIndex
                            Metadata = [PSCustomObject]@{
                                PcmStreamIndex = $pcmStreamIndex
                                Frames = $frames
                            }
                            ErrorMessage = $null
                        }
                    }
                    catch {
                        return [PSCustomObject]@{
                            Index = $fileIndex
                            Metadata = $null
                            ErrorMessage = (
                                "Could not read metadata for: " +
                                $filePath
                            )
                        }
                    }
                } -ArgumentList $FfprobePath, $file, $index

                [void]$activeJobs.Add(
                    [PSCustomObject]@{
                        Index = $index
                        File = $file
                        Job = $job
                    }
                )

                $nextIndex++
            }

            if ($activeJobs.Count -eq 0) {
                break
            }

            $jobsToWait = @(
                $activeJobs |
                    ForEach-Object {
                        $_.Job
                    }
            )

            $finishedJob = Wait-Job -Job $jobsToWait -Any

            if ($null -eq $finishedJob) {
                throw "Parallel media metadata generation failed unexpectedly."
            }

            $jobEntry =
                $activeJobs |
                    Where-Object {
                        $_.Job.Id -eq $finishedJob.Id
                    } |
                    Select-Object -First 1

            $jobResult = Receive-Job -Job $finishedJob -ErrorAction SilentlyContinue

            Remove-Job -Job $finishedJob -Force | Out-Null

            if ($null -ne $jobEntry) {
                [void]$activeJobs.Remove($jobEntry)
            }

            if ($finishedJob.State -ne "Completed") {
                throw (
                    "Parallel media metadata worker failed for: " +
                    $jobEntry.File
                )
            }

            if ($null -eq $jobResult) {
                throw (
                    "Parallel media metadata worker returned no data for: " +
                    $jobEntry.File
                )
            }

            if (-not [string]::IsNullOrWhiteSpace(
                [string]$jobResult.ErrorMessage
            )) {
                throw $jobResult.ErrorMessage
            }

            $results[[int]$jobResult.Index] = $jobResult.Metadata

            $completedCount++

            if (-not [string]::IsNullOrWhiteSpace($ProgressActivity)) {
                $stepPercent = 100.0 * $completedCount / $files.Count

                Set-StepProgress `
                    -Activity $ProgressActivity `
                    -Status "$completedCount/$($files.Count) files" `
                    -PercentComplete $stepPercent

                if (-not [string]::IsNullOrWhiteSpace($ProgressStage)) {
                    Set-OverallProgress `
                        -Stage $ProgressStage `
                        -PercentComplete $stepPercent `
                        -Status "Media metadata: $completedCount/$($files.Count)"
                }
            }
        }
    }
    finally {
        foreach ($entry in @($activeJobs)) {
            try {
                Stop-Job -Job $entry.Job -ErrorAction SilentlyContinue
            }
            catch {
            }

            try {
                Remove-Job -Job $entry.Job -Force -ErrorAction SilentlyContinue
            }
            catch {
            }
        }
    }

    for ($i = 0; $i -lt $files.Count; $i++) {
        if (-not $results.ContainsKey($i)) {
            throw "Missing media metadata result for file index $i"
        }
    }

    return $results
}

function Get-FrameHashes {
    param(
        [string]$File
    )

    $lines = @(
        & $ffmpeg `
            "-v" "quiet" `
            "-i" $File `
            "-map" "0:v:0" `
            "-an" `
            "-f" "framemd5" `
            "-"
    )

    if ($LASTEXITCODE -ne 0) {
        throw "Could not calculate frame hashes for: $File"
    }

    $hashes = New-Object System.Collections.Generic.List[string]

    foreach ($line in $lines) {

        if ([string]$line -like "#*" -or
            [string]::IsNullOrWhiteSpace($line)) {
            continue
        }

        $parts = ([string]$line) -split ","

        if ($parts.Count -ge 6) {
            [void]$hashes.Add($parts[5].Trim())
        }
    }

    return ,$hashes.ToArray()
}

function Get-FrameHashesParallel {
    param(
        [string[]]$InputFiles,
        [int]$WorkerCount,
        [string]$FfmpegPath,
        [string]$ProgressStage = "",
        [string]$ProgressActivity = ""
    )

    $files = @($InputFiles)
    $results = @{}

    if ($files.Count -eq 0) {
        return $results
    }

    $workerLimit = [Math]::Max(
        1,
        [Math]::Min($WorkerCount, $files.Count)
    )

    $completedCount = 0

    $activeJobs = New-Object System.Collections.ArrayList
    $nextIndex = 0

    try {
        while ($nextIndex -lt $files.Count -or $activeJobs.Count -gt 0) {

            while (
                $nextIndex -lt $files.Count -and
                $activeJobs.Count -lt $workerLimit
            ) {

                $index = $nextIndex
                $file = $files[$index]

                $job = Start-Job -ScriptBlock {
                    param(
                        [string]$ffmpegExe,
                        [string]$filePath,
                        [int]$fileIndex
                    )

                    $lines = @(
                        & $ffmpegExe `
                            "-v" "quiet" `
                            "-i" $filePath `
                            "-map" "0:v:0" `
                            "-an" `
                            "-f" "framemd5" `
                            "-"
                    )

                    if ($LASTEXITCODE -ne 0) {
                        return [PSCustomObject]@{
                            Index = $fileIndex
                            Hashes = @()
                            ErrorMessage = "Could not calculate frame hashes for: $filePath"
                        }
                    }

                    $hashes =
                        New-Object System.Collections.Generic.List[string]

                    foreach ($line in $lines) {
                        if ([string]$line -like "#*" -or
                            [string]::IsNullOrWhiteSpace($line)) {
                            continue
                        }

                        $parts = ([string]$line) -split ","

                        if ($parts.Count -ge 6) {
                            [void]$hashes.Add($parts[5].Trim())
                        }
                    }

                    return [PSCustomObject]@{
                        Index = $fileIndex
                        Hashes = $hashes.ToArray()
                        ErrorMessage = $null
                    }
                } -ArgumentList $FfmpegPath, $file, $index

                [void]$activeJobs.Add(
                    [PSCustomObject]@{
                        Index = $index
                        File = $file
                        Job = $job
                    }
                )

                $nextIndex++
            }

            if ($activeJobs.Count -eq 0) {
                break
            }

            $jobsToWait = @(
                $activeJobs |
                    ForEach-Object {
                        $_.Job
                    }
            )

            $finishedJob = Wait-Job -Job $jobsToWait -Any

            if ($null -eq $finishedJob) {
                throw "Parallel hash generation failed unexpectedly."
            }

            $jobEntry =
                $activeJobs |
                    Where-Object {
                        $_.Job.Id -eq $finishedJob.Id
                    } |
                    Select-Object -First 1

            $jobResult = Receive-Job -Job $finishedJob -ErrorAction SilentlyContinue

            Remove-Job -Job $finishedJob -Force | Out-Null

            if ($null -ne $jobEntry) {
                [void]$activeJobs.Remove($jobEntry)
            }

            if ($finishedJob.State -ne "Completed") {
                throw (
                    "Parallel hash worker failed for: " +
                    $jobEntry.File
                )
            }

            if ($null -eq $jobResult) {
                throw (
                    "Parallel hash worker returned no data for: " +
                    $jobEntry.File
                )
            }

            if (-not [string]::IsNullOrWhiteSpace(
                [string]$jobResult.ErrorMessage
            )) {
                throw $jobResult.ErrorMessage
            }

            $results[[int]$jobResult.Index] = @($jobResult.Hashes)

            $completedCount++

            if (-not [string]::IsNullOrWhiteSpace($ProgressActivity)) {
                $stepPercent = 100.0 * $completedCount / $files.Count

                Set-StepProgress `
                    -Activity $ProgressActivity `
                    -Status "$completedCount/$($files.Count) files" `
                    -PercentComplete $stepPercent

                if (-not [string]::IsNullOrWhiteSpace($ProgressStage)) {
                    Set-OverallProgress `
                        -Stage $ProgressStage `
                        -PercentComplete $stepPercent `
                        -Status "Frame hashes: $completedCount/$($files.Count)"
                }
            }
        }
    }
    finally {
        foreach ($entry in @($activeJobs)) {
            try {
                Stop-Job -Job $entry.Job -ErrorAction SilentlyContinue
            }
            catch {
            }

            try {
                Remove-Job -Job $entry.Job -Force -ErrorAction SilentlyContinue
            }
            catch {
            }
        }
    }

    for ($i = 0; $i -lt $files.Count; $i++) {
        if (-not $results.ContainsKey($i)) {
            throw "Missing hash result for file index $i"
        }
    }

    return $results
}

function Convert-ToStringArray {
    param(
        $InputItems
    )

    $result = New-Object System.Collections.Generic.List[string]

    foreach ($item in @($InputItems)) {
        [void]$result.Add([string]$item)
    }

    return $result.ToArray()
}

function Find-Overlap {
    param(
        $A,
        $B
    )

    $A = @(Convert-ToStringArray $A)
    $B = @(Convert-ToStringArray $B)

    $maxLength = [Math]::Min($A.Count, $B.Count)

    for ($length = $maxLength;
         $length -ge $MinimumMatchFrames;
         $length--) {

        $aStart = $A.Count - $length
        $match = $true

        for ($j = 0; $j -lt $length; $j++) {

            if ($A[$aStart + $j] -ne
                $B[$j]) {

                $match = $false
                break
            }
        }

        if ($match) {

            return [PSCustomObject]@{
                Length = $length
                AStart = $aStart
                BStart = 0
            }
        }
    }

    return $null
}

function Find-EventPrefixOverlap {
    param(
        $A,
        $B
    )

    $A = @(Convert-ToStringArray $A)
    $B = @(Convert-ToStringArray $B)

    # Dashcam event behavior:
    # REC = [unique beginning][tail]
    # EVT = [same tail][event footage]
    #
    # Search only for a suffix of REC matching the prefix of EVT.

    $maxLength = [Math]::Min($A.Count, $B.Count)

    for ($length = $maxLength;
         $length -ge $MinimumMatchFrames;
         $length--) {

        $aStart = $A.Count - $length
        $match = $true

        for ($j = 0; $j -lt $length; $j++) {

            if ($A[$aStart + $j] -ne
                $B[$j]) {

                $match = $false
                break
            }
        }

        if ($match) {

            return [PSCustomObject]@{
                Length = $length
                AStart = $aStart
                BStart = 0
            }
        }
    }

    return $null
}

function Find-DeepflyOneGapOverlap {
    param(
        $A,
        $B
    )

    $A = @(Convert-ToStringArray $A)
    $B = @(Convert-ToStringArray $B)

    # Deepfly DF10 behavior: REC and EVT normally share an exact boundary,
    # but the camera can occasionally include one additional frame in only
    # one file. Require exact matches on both sides of that single-frame gap.
    for ($aStart = 0; $aStart -lt $A.Count; $aStart++) {
        $aLength = $A.Count - $aStart

        # One extra frame in EVT (the current file).
        if ($aLength + 1 -le $B.Count) {
            $beforeGap = 0
            while ($beforeGap -lt $aLength -and
                $A[$aStart + $beforeGap] -eq $B[$beforeGap]) {
                $beforeGap++
            }

            $afterGap = $aLength - $beforeGap
            if ($beforeGap -ge $MinimumMatchFrames -and
                $afterGap -ge $MinimumMatchFrames) {

                $match = $true
                for ($offset = $beforeGap;
                     $offset -lt $aLength;
                     $offset++) {
                    if ($A[$aStart + $offset] -ne $B[$offset + 1]) {
                        $match = $false
                        break
                    }
                }

                if ($match) {
                    return [PSCustomObject]@{
                        Length = $aLength + 1
                        AStart = $aStart
                        BStart = 0
                        MatchedFrames = $aLength
                        ExtraFrameIn = "EVT"
                        GapIndex = $beforeGap
                    }
                }
            }
        }

        # One extra frame in REC (the previous file).
        if ($aLength - 1 -le $B.Count -and
            $aLength - 1 -ge 2 * $MinimumMatchFrames) {
            $beforeGap = 0
            while ($beforeGap -lt $aLength - 1 -and
                $A[$aStart + $beforeGap] -eq $B[$beforeGap]) {
                $beforeGap++
            }

            $afterGap = $aLength - $beforeGap - 1
            if ($beforeGap -ge $MinimumMatchFrames -and
                $afterGap -ge $MinimumMatchFrames) {

                $match = $true
                for ($offset = $beforeGap;
                     $offset -lt $aLength - 1;
                     $offset++) {
                    if ($A[$aStart + $offset + 1] -ne $B[$offset]) {
                        $match = $false
                        break
                    }
                }

                if ($match) {
                    return [PSCustomObject]@{
                        Length = $aLength - 1
                        AStart = $aStart
                        BStart = 0
                        MatchedFrames = $aLength - 1
                        ExtraFrameIn = "REC"
                        GapIndex = $beforeGap
                    }
                }
            }
        }
    }

    return $null
}

function Find-ContainedFrameSequence {
    param(
        $ContainerHashes,
        $CandidateHashes
    )

    $container = @(Convert-ToStringArray $ContainerHashes)
    $candidate = @(Convert-ToStringArray $CandidateHashes)

    if ($candidate.Count -lt $MinimumMatchFrames -or
        $candidate.Count -gt $container.Count) {
        return $null
    }

    for ($start = 0;
         $start -le $container.Count - $candidate.Count;
         $start++) {
        $match = $true

        for ($offset = 0; $offset -lt $candidate.Count; $offset++) {
            if ($container[$start + $offset] -ne $candidate[$offset]) {
                $match = $false
                break
            }
        }

        if ($match) {
            return [PSCustomObject]@{
                Start = $start
                Length = $candidate.Count
            }
        }
    }

    return $null
}

function Find-OverlapWithEventFallback {
    param(
        [string]$PreviousFile,
        [string]$CurrentFile,
        $PreviousHashes,
        $CurrentHashes
    )

    $overlap = Find-Overlap $PreviousHashes $CurrentHashes

    if ($null -ne $overlap) {
        return [PSCustomObject]@{
            Result = $overlap
            IsEventOverlap = $false
            IsDeepflyHandoff = $false
            IsDeepflyOneGapOverlap = $false
        }
    }

    # Keep the special search narrow: only short REC -> EVT pairs.
    $previousName = [IO.Path]::GetFileName($PreviousFile)
    $currentName  = [IO.Path]::GetFileName($CurrentFile)

    $previousIsRecording = $previousName.StartsWith(
        $RecordingFilePrefix,
        [StringComparison]::OrdinalIgnoreCase
    )
    $previousIsEvent = $previousName.StartsWith(
        $EventFilePrefix,
        [StringComparison]::OrdinalIgnoreCase
    )
    $currentIsRecording = $currentName.StartsWith(
        $RecordingFilePrefix,
        [StringComparison]::OrdinalIgnoreCase
    )
    $currentIsEvent = $currentName.StartsWith(
        $EventFilePrefix,
        [StringComparison]::OrdinalIgnoreCase
    )

    $previousFrameCount = @($PreviousHashes).Count
    $previousDuration =
        Get-VideoDurationFromFrames $previousFrameCount

    if ($previousIsRecording -and
        $currentIsEvent -and
        $previousDuration -le 10.0) {

        Write-Host ""
        Write-Host "No normal boundary overlap."
        Write-Host "Checking for REC tail at start of EVT..."

        $eventOverlap =
            Find-EventPrefixOverlap `
                $PreviousHashes `
                $CurrentHashes

        if ($null -ne $eventOverlap) {

            return [PSCustomObject]@{
                Result = $eventOverlap
                IsEventOverlap = $true
                IsDeepflyHandoff = $false
                IsDeepflyOneGapOverlap = $false
            }
        }
    }

    $previousHashValues = @(Convert-ToStringArray $PreviousHashes)
    $currentHashValues = @(Convert-ToStringArray $CurrentHashes)

    if ($previousIsRecording -and $currentIsEvent) {
        $oneGapOverlap = Find-DeepflyOneGapOverlap `
            $previousHashValues `
            $currentHashValues

        if ($null -ne $oneGapOverlap) {
            return [PSCustomObject]@{
                Result = $oneGapOverlap
                IsEventOverlap = $true
                IsDeepflyHandoff = $false
                IsDeepflyOneGapOverlap = $true
            }
        }
    }

    # Deepfly DF10 behavior: an EVT file and the following REC file can share
    # only a few boundary frames. Keep the normal threshold for every other
    # case, but accept the longest exact DF10 handoff below that threshold.
    if ($previousIsEvent -and
        $currentIsRecording -and
        $previousHashValues.Count -gt 0 -and
        $currentHashValues.Count -gt 0) {

        $maximumHandoffLength = [Math]::Min(
            $MinimumMatchFrames - 1,
            [Math]::Min(
                $previousHashValues.Count,
                $currentHashValues.Count
            )
        )

        for ($handoffLength = $maximumHandoffLength;
             $handoffLength -ge 1;
             $handoffLength--) {
            $handoffStart = $previousHashValues.Count - $handoffLength
            $handoffMatches = $true

            for ($offset = 0; $offset -lt $handoffLength; $offset++) {
                if ($previousHashValues[$handoffStart + $offset] -ne
                    $currentHashValues[$offset]) {
                    $handoffMatches = $false
                    break
                }
            }

            if (-not $handoffMatches) {
                continue
            }

            return [PSCustomObject]@{
                Result = [PSCustomObject]@{
                    Length = $handoffLength
                    AStart = $handoffStart
                    BStart = 0
                }
                IsEventOverlap = $false
                IsDeepflyHandoff = $true
                IsDeepflyOneGapOverlap = $false
            }
        }
    }

    return [PSCustomObject]@{
        Result = $null
        IsEventOverlap = $false
        IsDeepflyHandoff = $false
        IsDeepflyOneGapOverlap = $false
    }
}

function Get-DeepflyContainedFilePlan {
    param(
        [string[]]$InputFiles,
        [hashtable]$FrameHashes
    )

    $retainedIndices = New-Object System.Collections.Generic.List[int]
    $skippedFiles = New-Object System.Collections.Generic.List[object]

    for ($index = 0; $index -lt $InputFiles.Count; $index++) {
        if ($index -eq 0 -or $index -eq $InputFiles.Count - 1) {
            [void]$retainedIndices.Add($index)
            continue
        }

        $previousIndex = $retainedIndices[$retainedIndices.Count - 1]
        $nextIndex = $index + 1
        $previousName = [IO.Path]::GetFileName($InputFiles[$previousIndex])
        $candidateName = [IO.Path]::GetFileName($InputFiles[$index])
        $nextName = [IO.Path]::GetFileName($InputFiles[$nextIndex])

        $isDeepflyContainedCandidate = (
            $previousName.StartsWith(
                $EventFilePrefix,
                [StringComparison]::OrdinalIgnoreCase
            ) -and
            $candidateName.StartsWith(
                $RecordingFilePrefix,
                [StringComparison]::OrdinalIgnoreCase
            ) -and
            $nextName.StartsWith(
                $RecordingFilePrefix,
                [StringComparison]::OrdinalIgnoreCase
            )
        )

        if (-not $isDeepflyContainedCandidate) {
            [void]$retainedIndices.Add($index)
            continue
        }

        # Deepfly DF10 can occasionally produce a short REC file containing
        # only frames already present inside the preceding EVT. Skip it only
        # when every frame is contained and bypassing it reconnects cleanly.
        $containedSequence = Find-ContainedFrameSequence `
            $FrameHashes[$previousIndex] `
            $FrameHashes[$index]

        if ($null -eq $containedSequence) {
            [void]$retainedIndices.Add($index)
            continue
        }

        $bypassOverlap = Find-OverlapWithEventFallback `
            $InputFiles[$previousIndex] `
            $InputFiles[$nextIndex] `
            $FrameHashes[$previousIndex] `
            $FrameHashes[$nextIndex]

        if ($null -eq $bypassOverlap.Result) {
            [void]$retainedIndices.Add($index)
            continue
        }

        [void]$skippedFiles.Add(
            [PSCustomObject]@{
                Index = $index
                PreviousIndex = $previousIndex
                NextIndex = $nextIndex
                ContainedStart = $containedSequence.Start
                FrameCount = $containedSequence.Length
                BypassOverlapLength = $bypassOverlap.Result.Length
            }
        )
    }

    return [PSCustomObject]@{
        RetainedIndices = @($retainedIndices.ToArray())
        SkippedFiles = @($skippedFiles.ToArray())
    }
}

function Get-PCMStreamIndex {
    param(
        [string]$File
    )

    # The dashcam can contain a bogus/broken MP3 stream alongside
    # the real PCM audio. Only use the PCM track.
    $result = @(
        & $ffprobe `
            "-v" "quiet" `
            "-select_streams" "a" `
            "-show_entries" "stream=index,codec_name" `
            "-of" "csv=p=0" `
            $File 2>$null
    )

    foreach ($line in $result) {
        if ([string]::IsNullOrWhiteSpace([string]$line)) {
            continue
        }

        $parts = ([string]$line) -split ","

        if ($parts.Count -lt 2) {
            continue
        }

        if ($parts[1].Trim().ToLowerInvariant() -eq "pcm_s16le") {
            try {
                return [int]$parts[0].Trim()
            }
            catch {
                continue
            }
        }
    }

    return -1
}

function Get-VideoDurationFromFrames {
param(
    [int]$FrameCount
)

return $FrameCount / $FrameRateValue
}

function Convert-DraggedFileList {
    param(
        [string]$Text
    )

    $paths = New-Object System.Collections.Generic.List[string]
    $pathMatches = [regex]::Matches(
        $Text,
        '"([^"]*)"|''((?:''''|[^''])*)''|(\S+)'
    )

    foreach ($match in $pathMatches) {
        if ($match.Groups[1].Success) {
            $path = $match.Groups[1].Value.Trim()
        }
        elseif ($match.Groups[2].Success) {
            $path = $match.Groups[2].Value.Replace("''", "'").Trim()
        }
        else {
            $path = $match.Groups[3].Value.Trim()
        }

        if (
            -not [string]::IsNullOrWhiteSpace($path) -and
            $path -ne "&"
        ) {
            [void]$paths.Add($path)
        }
    }

    return $paths.ToArray()
}

$script:FallbackSortMode = $null

function Get-FileNameTimestampSortMetadata {
    param(
        [string]$FileName,
        [string]$RecordingPrefix,
        [string]$EventPrefix
    )

    $baseName = [IO.Path]::GetFileNameWithoutExtension($FileName)

    $escapedRecordingPrefix = [regex]::Escape($RecordingPrefix)
    $escapedEventPrefix = [regex]::Escape($EventPrefix)
    $pattern = (
        "^(?<prefix>(?:" +
        $escapedRecordingPrefix +
        "|" +
        $escapedEventPrefix +
        "))?(?<date>\d{8})_(?<time>\d{6})"
    )

    $match = [regex]::Match(
        $baseName,
        $pattern,
        [System.Text.RegularExpressions.RegexOptions]::IgnoreCase
    )

    if (-not $match.Success) {
        return [PSCustomObject]@{
            ParseSuccess = $false
            Timestamp = [datetime]::MinValue
            TypePriority = 2
        }
    }

    $timestampText = (
        $match.Groups["date"].Value +
        $match.Groups["time"].Value
    )

    try {
        $timestamp = [datetime]::ParseExact(
            $timestampText,
            "yyyyMMddHHmmss",
            [Globalization.CultureInfo]::InvariantCulture
        )
    }
    catch {
        return [PSCustomObject]@{
            ParseSuccess = $false
            Timestamp = [datetime]::MinValue
            TypePriority = 2
        }
    }

    $typePriority = 2
    $prefixUpper = [string]$match.Groups["prefix"].Value

    if ($prefixUpper.Equals($RecordingPrefix, [StringComparison]::OrdinalIgnoreCase)) {
        $typePriority = 0
    }
    elseif ($prefixUpper.Equals($EventPrefix, [StringComparison]::OrdinalIgnoreCase)) {
        $typePriority = 1
    }

    return [PSCustomObject]@{
        ParseSuccess = $true
        Timestamp = $timestamp
        TypePriority = $typePriority
    }
}

function Get-SortedInputFileInfos {
    param(
        [string[]]$FilePaths,
        [bool]$AllowFallbackPrompt = $true
    )

    $records = New-Object System.Collections.Generic.List[object]

    foreach ($path in $FilePaths) {
        if ([string]::IsNullOrWhiteSpace([string]$path)) {
            continue
        }

        $fileInfo = Get-Item -LiteralPath ([string]$path)
        $metadata = Get-FileNameTimestampSortMetadata `
            -FileName $fileInfo.Name `
            -RecordingPrefix $RecordingFilePrefix `
            -EventPrefix $EventFilePrefix

        [void]$records.Add(
            [PSCustomObject]@{
                FileInfo = $fileInfo
                ParseSuccess = [bool]$metadata.ParseSuccess
                ParsedTimestamp = [datetime]$metadata.Timestamp
                TypePriority = [int]$metadata.TypePriority
            }
        )
    }

    if ($records.Count -eq 0) {
        return [PSCustomObject]@{
            Items = @()
            SortMode = "None"
            ParseableCount = 0
            TotalCount = 0
        }
    }

    $parseableCount = @(
        $records |
            Where-Object {
                $_.ParseSuccess
            }
    ).Count

    $sortMode = ""
    $sorted = @()

    if ($parseableCount -eq $records.Count) {
        $sortMode = "ParsedTimestamp"

        $sorted = @(
            $records |
                Sort-Object `
                    ParsedTimestamp,
                    TypePriority,
                    @{ Expression = { $_.FileInfo.Name }; Ascending = $true }
        )
    }
    else {
        if ($parseableCount -gt 0) {
            if ($AllowFallbackPrompt) {
                Write-Host ""
                Write-Host "Some filenames do not match the expected timestamp pattern."
                Write-Host "Parsed timestamps: $parseableCount/$($records.Count)"
                Write-Host "Choose behavior for files that could not be parsed:"
                Write-Host "[1] Keep parsed sort for parseable files; append unparseable files using fallback sort (default)"
                Write-Host "[2] Use fallback sort mode for all files"
            }

            $useFallbackForAll = $false
            if ($AllowFallbackPrompt) {
                while ($true) {
                    $behaviorChoice = Read-Host "Select [1/2] (press Enter for 1)"

                    if ([string]::IsNullOrWhiteSpace($behaviorChoice) -or
                        $behaviorChoice -eq "1") {
                        $useFallbackForAll = $false
                        break
                    }

                    if ($behaviorChoice -eq "2") {
                        $useFallbackForAll = $true
                        break
                    }

                    Write-Host "Please enter 1 or 2."
                }
            }

            if (-not $useFallbackForAll) {
                if ($AllowFallbackPrompt) {
                    Write-Host "Choose fallback sort mode for unparseable files:"
                    Write-Host "[1] Filename (default)"
                    Write-Host "[2] Modified date"
                }

                if ([string]::IsNullOrWhiteSpace($script:FallbackSortMode)) {
                    if ($AllowFallbackPrompt) {
                        while ($true) {
                            $choice = Read-Host "Select [1/2] (press Enter for 1)"

                            if ([string]::IsNullOrWhiteSpace($choice) -or $choice -eq "1") {
                                $script:FallbackSortMode = "Filename"
                                break
                            }

                            if ($choice -eq "2") {
                                $script:FallbackSortMode = "ModifiedDate"
                                break
                            }

                            Write-Host "Please enter 1 or 2."
                        }
                    }
                    else {
                        $script:FallbackSortMode = "Filename"
                    }
                }
                elseif ($AllowFallbackPrompt) {
                    Write-Host "Using fallback sort mode selected earlier: $script:FallbackSortMode"
                }

                $parsedRecords = @(
                    $records |
                        Where-Object {
                            $_.ParseSuccess
                        } |
                        Sort-Object `
                            ParsedTimestamp,
                            TypePriority,
                            @{ Expression = { $_.FileInfo.Name }; Ascending = $true }
                )

                if ($script:FallbackSortMode -eq "ModifiedDate") {
                    $unparsedRecords = @(
                        $records |
                            Where-Object {
                                -not $_.ParseSuccess
                            } |
                            Sort-Object `
                                @{ Expression = { $_.FileInfo.LastWriteTime }; Ascending = $true },
                                @{ Expression = { $_.FileInfo.Name }; Ascending = $true }
                    )
                    $sortMode = "ParsedTimestamp+FallbackModifiedDate"
                }
                else {
                    $unparsedRecords = @(
                        $records |
                            Where-Object {
                                -not $_.ParseSuccess
                            } |
                            Sort-Object `
                                @{ Expression = { $_.FileInfo.Name }; Ascending = $true }
                    )
                    $sortMode = "ParsedTimestamp+FallbackFilename"
                }

                $sorted = @($parsedRecords + $unparsedRecords)
            }
            else {
                if ($AllowFallbackPrompt) {
                    Write-Host "Choose fallback sort mode for all files:"
                    Write-Host "[1] Filename (default)"
                    Write-Host "[2] Modified date"
                }

                if ([string]::IsNullOrWhiteSpace($script:FallbackSortMode)) {
                    if ($AllowFallbackPrompt) {
                        while ($true) {
                            $choice = Read-Host "Select [1/2] (press Enter for 1)"

                            if ([string]::IsNullOrWhiteSpace($choice) -or $choice -eq "1") {
                                $script:FallbackSortMode = "Filename"
                                break
                            }

                            if ($choice -eq "2") {
                                $script:FallbackSortMode = "ModifiedDate"
                                break
                            }

                            Write-Host "Please enter 1 or 2."
                        }
                    }
                    else {
                        $script:FallbackSortMode = "Filename"
                    }
                }
                elseif ($AllowFallbackPrompt) {
                    Write-Host "Using fallback sort mode selected earlier: $script:FallbackSortMode"
                }

                if ($script:FallbackSortMode -eq "ModifiedDate") {
                    $sortMode = "ModifiedDate"
                    $sorted = @(
                        $records |
                            Sort-Object `
                                @{ Expression = { $_.FileInfo.LastWriteTime }; Ascending = $true },
                                @{ Expression = { $_.FileInfo.Name }; Ascending = $true }
                    )
                }
                else {
                    $sortMode = "Filename"
                    $sorted = @(
                        $records |
                            Sort-Object `
                                @{ Expression = { $_.FileInfo.Name }; Ascending = $true }
                    )
                }
            }
        }
        elseif ($AllowFallbackPrompt) {
            Write-Host ""
            Write-Host "Some filenames do not match the expected timestamp pattern."
            Write-Host "Parsed timestamps: $parseableCount/$($records.Count)"
            Write-Host "Choose fallback sort mode for this run:"
            Write-Host "[1] Filename (default)"
            Write-Host "[2] Modified date"

            if ([string]::IsNullOrWhiteSpace($script:FallbackSortMode)) {
                while ($true) {
                    $choice = Read-Host "Select [1/2] (press Enter for 1)"

                    if ([string]::IsNullOrWhiteSpace($choice) -or $choice -eq "1") {
                        $script:FallbackSortMode = "Filename"
                        break
                    }

                    if ($choice -eq "2") {
                        $script:FallbackSortMode = "ModifiedDate"
                        break
                    }

                    Write-Host "Please enter 1 or 2."
                }
            }
            else {
                Write-Host "Using fallback sort mode selected earlier: $script:FallbackSortMode"
            }

            if ($script:FallbackSortMode -eq "ModifiedDate") {
                $sortMode = "ModifiedDate"
                $sorted = @(
                    $records |
                        Sort-Object `
                            @{ Expression = { $_.FileInfo.LastWriteTime }; Ascending = $true },
                            @{ Expression = { $_.FileInfo.Name }; Ascending = $true }
                )
            }
            else {
                $sortMode = "Filename"
                $sorted = @(
                    $records |
                        Sort-Object `
                            @{ Expression = { $_.FileInfo.Name }; Ascending = $true }
                )
            }
        }
        else {
            if ([string]::IsNullOrWhiteSpace($script:FallbackSortMode)) {
                $script:FallbackSortMode = "Filename"
            }

            if ($script:FallbackSortMode -eq "ModifiedDate") {
                $sortMode = "ModifiedDate"
                $sorted = @(
                    $records |
                        Sort-Object `
                            @{ Expression = { $_.FileInfo.LastWriteTime }; Ascending = $true },
                            @{ Expression = { $_.FileInfo.Name }; Ascending = $true }
                )
            }
            else {
                $sortMode = "Filename"
                $sorted = @(
                    $records |
                        Sort-Object `
                            @{ Expression = { $_.FileInfo.Name }; Ascending = $true }
                )
            }
        }
    }

    return [PSCustomObject]@{
        Items = @($sorted | ForEach-Object { $_.FileInfo })
        SortMode = $sortMode
        ParseableCount = $parseableCount
        TotalCount = $records.Count
    }
}

function Select-OutputDirectory {
    param(
        [string]$SourceDirectory
    )

    $registryPath = "HKCU:\Software\DashcamVideoMergerSplitter"
    $lastDirectory = $null

    try {
        $lastDirectory = (Get-ItemProperty `
            -Path $registryPath `
            -Name LastOutputDirectory `
            -ErrorAction Stop
        ).LastOutputDirectory
    }
    catch {
        $lastDirectory = $null
    }

    $lastDirectoryIsValid = (
        -not [string]::IsNullOrWhiteSpace($lastDirectory) -and
        (Test-Path -LiteralPath $lastDirectory -PathType Container)
    )

    Write-Host ""
    Write-Host "Output folder:"
    if ([string]::IsNullOrWhiteSpace($lastDirectory)) {
        Write-Host "[1] Last folder (default): not set"
    }
    elseif ($lastDirectoryIsValid) {
        Write-Host "[1] Last folder (default): $lastDirectory"
    }
    else {
        Write-Host "[1] Last folder (default): $lastDirectory (not available)"
    }
    Write-Host "[2] Same folder as videos"
    Write-Host "[3] Browse..."

    while ($true) {
        $choice = Read-Host "Select [1/2/3] (press Enter for 1)"

        if ([string]::IsNullOrWhiteSpace($choice) -or $choice -eq "1") {
            if ($lastDirectoryIsValid) {
                $selectedDirectory = [IO.Path]::GetFullPath($lastDirectory)
            }
            else {
                $selectedDirectory = $SourceDirectory
                Write-Host "No valid last folder found. Using the folder containing the videos."
            }
            break
        }

        if ($choice -eq "2") {
            $selectedDirectory = $SourceDirectory
            break
        }

        if ($choice -eq "3") {
            $selectedDirectory = $null

            for (
                $attempt = 0;
                $attempt -lt 1;
                $attempt++
            ) {
                $selectedDirectory = & powershell.exe -NoProfile -STA -Command `
                    "Add-Type -AssemblyName System.Windows.Forms; `$dialog = New-Object System.Windows.Forms.FolderBrowserDialog; `$dialog.Description = 'Choose output folder'; if (`$dialog.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) { `$dialog.SelectedPath }"
            }

            if (-not [string]::IsNullOrWhiteSpace($selectedDirectory)) {
                break
            }

            Write-Host "No folder selected. Using the folder containing the videos."
            $selectedDirectory = $SourceDirectory
            break
        }

        Write-Host "Please enter 1, 2, or 3."
    }

    if (-not (Test-Path -LiteralPath $selectedDirectory -PathType Container)) {
        New-Item -ItemType Directory -Path $selectedDirectory -Force | Out-Null
    }

    $selectedDirectory = [IO.Path]::GetFullPath($selectedDirectory)

    try {
        New-Item -Path $registryPath -Force | Out-Null
        Set-ItemProperty `
            -Path $registryPath `
            -Name LastOutputDirectory `
            -Value $selectedDirectory
    }
    catch {
        Write-Host "Could not save the last output folder."
    }

    return $selectedDirectory
}

# ============================================================
# Validate input
# ============================================================

if ($null -eq $Files) {
    $Files = @()
}

while ($Files.Count -lt 2) {
    Write-Host ""
    Write-Host (
        "Drag dashcam video files into this window, then press Enter. " +
        "At least two files are required. Currently selected: $($Files.Count)"
    )

    $draggedText = Read-Host "Files"
    if ([string]::IsNullOrWhiteSpace($draggedText)) {
        continue
    }

    $draggedFiles = @(Convert-DraggedFileList $draggedText)
    if ($draggedFiles.Count -eq 0) {
        Write-Host "No file paths were detected. Please try again."
        continue
    }

    $Files = @($Files) + $draggedFiles
}

$initialSort = Get-SortedInputFileInfos -FilePaths $Files
$initialFiles = @($initialSort.Items)

Write-Host ""
Write-Host "Initial files after sorting:"
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

$additionalText = Read-Host (
    "Do you want to add additional files (like event videos)? " +
    "Drag them here and press Enter, or press Enter to skip"
)

if (-not [string]::IsNullOrWhiteSpace($additionalText)) {

    $additionalFiles = Convert-DraggedFileList $additionalText

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
        $audioChoice = Read-Host "Include audio? (Y/n, press Enter for Y)"

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

Assert-MergeFreeSpace `
    -InputFiles $Files `
    -OutputDirectory $OutputDirectory `
    -TempDirectory $env:TEMP `
    -IncludeAudio (-not $ExcludeAudio)

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

$tempRoot = Join-Path $env:TEMP (
    "dashcam_merge_" + [guid]::NewGuid().ToString("N")
)

New-Item -ItemType Directory -Path $tempRoot | Out-Null

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
            $answer = Read-Host "Continue by skipping failed files? [Y/N]"
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
            $answer = Read-Host "Continue using $FrameRate fps anyway? [Y/N]"
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
# Helpers: inspect and create one audio segment
# --------------------------------------------------------

function Get-AudioPacketEndTime {
param(
    [string]$InputFile,
    [int]$AudioStreamIndex
)

    $packetLines = @(
        Invoke-FFprobe @(
            "-v", "error",
            "-select_streams", ([string]$AudioStreamIndex),
            "-show_packets",
            "-show_entries", "packet=pts_time,duration_time",
            "-of", "csv=p=0",
            $InputFile
        )
    )

    $endTime = $null

    foreach ($line in $packetLines) {
        $parts = ([string]$line) -split ","
        if ($parts.Count -lt 2) {
            continue
        }

        try {
            $packetStart = [double]::Parse(
                $parts[0].Trim(),
                [Globalization.CultureInfo]::InvariantCulture
            )
            $packetDuration = [double]::Parse(
                $parts[1].Trim(),
                [Globalization.CultureInfo]::InvariantCulture
            )
            $packetEnd = $packetStart + $packetDuration

            if ($null -eq $endTime -or $packetEnd -gt $endTime) {
                $endTime = $packetEnd
            }
        }
        catch {
            continue
        }
    }

    return $endTime
}

function Create-AudioSegment {
param(
    [string]$InputFile,
    [string]$OutputFile,
    [double]$StartTime,
    [double]$Duration,
    [bool]$HasAudio,
    [int]$AudioStreamIndex
)

    if ($Duration -le 0) {
        return
    }

    $durationText =
        $Duration.ToString(
            "0.000000",
            [Globalization.CultureInfo]::InvariantCulture
        )

    if ($HasAudio) {

        Write-Info (
            "Audio: " +
            [IO.Path]::GetFileName($InputFile) +
            " start=" +
            $StartTime.ToString(
                "0.000000",
                [Globalization.CultureInfo]::InvariantCulture
            ) +
            " duration=" +
            $durationText
        )

        $startText =
            $StartTime.ToString(
                "0.000000",
                [Globalization.CultureInfo]::InvariantCulture
            )

        $audioEndTime = Get-AudioPacketEndTime `
            $InputFile `
            $AudioStreamIndex

        $availableDuration = 0.0
        if ($null -ne $audioEndTime) {
            $availableDuration = [Math]::Max(
                0.0,
                [double]$audioEndTime - $StartTime
            )
        }

        $missingDuration = $Duration - $availableDuration
        $repairMinimumSeconds = 0.001
        $tailInputDuration = [Math]::Min(
            $AudioBoundaryRepairTailSeconds,
            $availableDuration
        )
        $tailOutputDuration =
            $tailInputDuration +
            $missingDuration +
            $AudioBoundaryRepairCompensationSeconds
        $tempo = 1.0
        if ($tailOutputDuration -gt 0) {
            $tempo = $tailInputDuration / $tailOutputDuration
        }
        $canRepairBoundary = (
            $EnableAudioBoundaryRepair -and
            $availableDuration -gt $repairMinimumSeconds -and
            $missingDuration -gt $repairMinimumSeconds -and
            $missingDuration -le $AudioBoundaryRepairMaximumGapSeconds -and
            $tempo -ge 0.5
        )

        $fadeDuration = [Math]::Min(
            $AudioBoundaryRepairFadeSeconds,
            $Duration / 2.0
        )
        $fadeText = $fadeDuration.ToString(
            "0.000000",
            [Globalization.CultureInfo]::InvariantCulture
        )
        $fadeOutStartText = ($Duration - $fadeDuration).ToString(
            "0.000000",
            [Globalization.CultureInfo]::InvariantCulture
        )

        if ($canRepairBoundary) {
            $headDuration = $availableDuration - $tailInputDuration

            $availableText = $availableDuration.ToString(
                "0.000000",
                [Globalization.CultureInfo]::InvariantCulture
            )
            $headText = $headDuration.ToString(
                "0.000000",
                [Globalization.CultureInfo]::InvariantCulture
            )
            $tempoText = $tempo.ToString(
                "0.000000",
                [Globalization.CultureInfo]::InvariantCulture
            )

            if ($headDuration -gt $repairMinimumSeconds) {
                $repairFilter = (
                    "[0:$AudioStreamIndex]" +
                    "atrim=duration=$availableText," +
                    "asetpts=PTS-STARTPTS,asplit=2[headsrc][tailsrc];" +
                    "[headsrc]atrim=duration=$headText," +
                    "asetpts=PTS-STARTPTS[head];" +
                    "[tailsrc]atrim=start=$headText," +
                    "asetpts=PTS-STARTPTS,atempo=$tempoText[tail];" +
                    "[head][tail]concat=n=2:v=0:a=1," +
                    "apad=whole_dur=$durationText," +
                    "atrim=duration=$durationText," +
                    "afade=t=in:st=0:d=$fadeText," +
                    "afade=t=out:st=${fadeOutStartText}:d=$fadeText[out]"
                )
            }
            else {
                $repairFilter = (
                    "[0:$AudioStreamIndex]" +
                    "atrim=duration=$availableText," +
                    "asetpts=PTS-STARTPTS," +
                    "atempo=$tempoText," +
                    "apad=whole_dur=$durationText," +
                    "atrim=duration=$durationText," +
                    "afade=t=in:st=0:d=$fadeText," +
                    "afade=t=out:st=${fadeOutStartText}:d=$fadeText[out]"
                )
            }

            Write-Info (
                "Audio boundary repair: stretched final " +
                $tailInputDuration.ToString(
                    "0.000",
                    [Globalization.CultureInfo]::InvariantCulture
                ) +
                "s to fill " +
                $missingDuration.ToString(
                    "0.000",
                    [Globalization.CultureInfo]::InvariantCulture
                ) +
                "s"
            )

            Run-FFmpeg @(
                "-y",
                "-ss", $startText,
                "-i", $InputFile,
                "-filter_complex", $repairFilter,
                "-map", "[out]",
                "-vn",
                "-sn",
                "-dn",
                "-t", $durationText,
                "-c:a", "pcm_s16le",
                $OutputFile
            )

            [void]$audioBoundaryRepairs.Add(
                [PSCustomObject]@{
                    File = [IO.Path]::GetFileName($InputFile)
                    GapSeconds = $missingDuration
                    TailSeconds = $tailInputDuration
                    CompensationSeconds =
                        $AudioBoundaryRepairCompensationSeconds
                    Tempo = $tempo
                }
            )

            return
        }

        Run-FFmpeg @(
            "-y",
            "-ss", $startText,
            "-i", $InputFile,
            "-map", "0:$AudioStreamIndex",
            "-vn",
            "-sn",
            "-dn",
            "-af",
            (
                "apad=whole_dur=$durationText," +
                "atrim=duration=$durationText," +
                "afade=t=in:st=0:d=$fadeText," +
                "afade=t=out:st=${fadeOutStartText}:d=$fadeText"
            ),
            "-t", $durationText,
            "-c:a", "pcm_s16le",
            $OutputFile
        )
    }
    else {

        Write-Info (
            "Audio: NO AUDIO - inserting " +
            $durationText +
            " seconds of silence"
        )

        Run-FFmpeg @(
            "-y",
            "-f", "lavfi",
            "-i",
            "anullsrc=r=16000:cl=mono",
            "-t", $durationText,
            "-c:a", "pcm_s16le",
            $OutputFile
        )
    }
}

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

    Remove-Item `
        -LiteralPath $tempRoot `
        -Recurse `
        -Force `
        -ErrorAction SilentlyContinue

    if (-not $mergeSucceeded) {
        pause
    }
}

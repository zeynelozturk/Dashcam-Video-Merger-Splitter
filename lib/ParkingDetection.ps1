# Detects sustained stationary (parked) spans in a dashcam file using
# ffmpeg's built-in scene-change score on a bottom-of-frame ROI, so the
# main pipeline can optionally crop them out of the merged output.
#
# Tuning constants below were validated experimentally (see
# experiment/parking-detection branch): a 2fps sample rate on a
# bottom-40%-of-frame crop cleanly separates driving (~0.05 avg score,
# spikes to 0.4+) from stationary (~0.02 avg, <=0.06 max), and stays low
# even when nearby traffic/pedestrians pass, because they normally do not
# appear on the road surface directly ahead of the car.
$script:ParkDetectionSampleFps = 2.0
if ($null -eq $script:ParkDetectionScoreThreshold -or
    $script:ParkDetectionScoreThreshold -le 0) {
    $script:ParkDetectionScoreThreshold = 0.005
}
if ($null -eq $script:ParkDetectionStartMarginSeconds -or
    $script:ParkDetectionStartMarginSeconds -lt 0) {
    $script:ParkDetectionStartMarginSeconds = 30.0
}
if ($null -eq $script:ParkDetectionEndMarginSeconds -or
    $script:ParkDetectionEndMarginSeconds -lt 0) {
    $script:ParkDetectionEndMarginSeconds = 5.0
}

function Get-ParkStationaryRuns {
    param(
        [string]$File
    )

    $vf = (
        "crop=iw:ih*0.4:0:ih*0.6," +
        "fps=$($script:ParkDetectionSampleFps)," +
        "select=gte(scene\,0)," +
        "metadata=print:key=lavfi.scene_score"
    )

    $stderrLog = Join-Path $env:TEMP (
        "dashcam_park_ffmpeg_" + [guid]::NewGuid().ToString("N") + ".log"
    )

    $lines = @()
    $previousErrorActionPreference = $ErrorActionPreference

    try {
        $ErrorActionPreference = "Continue"

        & $ffmpeg @(
            "-hide_banner",
            "-loglevel", "info",
            "-nostats",
            "-y",
            "-i", $File,
            "-vf", $vf,
            "-map", "0:v:0",
            "-an",
            "-f", "null", "-"
        ) 1>$null 2>$stderrLog

        $exitCode = $LASTEXITCODE

        if (Test-Path -LiteralPath $stderrLog -PathType Leaf) {
            $lines = @(Get-Content -LiteralPath $stderrLog)
        }

        if ($exitCode -ne 0) {
            $detailText = (@($lines) -join [Environment]::NewLine)
            throw (
                "FFmpeg parked-segment detection failed with exit code $exitCode" +
                [Environment]::NewLine +
                "Command: -i $File -vf $vf -map 0:v:0 -an -f null -" +
                [Environment]::NewLine +
                $detailText
            )
        }
    }
    finally {
        $ErrorActionPreference = $previousErrorActionPreference

        if (Test-Path -LiteralPath $stderrLog -PathType Leaf) {
            Remove-Item -LiteralPath $stderrLog -Force -ErrorAction SilentlyContinue
        }
    }

    $samples = New-Object System.Collections.Generic.List[object]

    $pendingTime = $null

    foreach ($line in $lines) {
        if ([string]::IsNullOrWhiteSpace([string]$line)) {
            continue
        }

        if ($line -match "pts_time:\s*([0-9.]+)") {
            try {
                $pendingTime = [double]::Parse(
                    $Matches[1],
                    [Globalization.CultureInfo]::InvariantCulture
                )
            }
            catch {
                $pendingTime = $null
            }
        }

        if ($line -match "lavfi\.scene_score=\s*([0-9.eE+-]+)") {
            if ($null -eq $pendingTime) {
                continue
            }

            try {
                $score = [double]::Parse(
                    $Matches[1],
                    [Globalization.CultureInfo]::InvariantCulture
                )
            }
            catch {
                continue
            }

            [void]$samples.Add(
                [PSCustomObject]@{ Time = $pendingTime; Score = $score }
            )
            $pendingTime = $null
        }
    }

    $runs = New-Object System.Collections.Generic.List[object]
    $runStart = $null
    $prevTime = $null

    foreach ($sample in $samples) {

        if ($sample.Score -le $script:ParkDetectionScoreThreshold) {
            if ($null -eq $runStart) {
                $runStart = $sample.Time
            }
        }
        else {
            if ($null -ne $runStart -and $null -ne $prevTime) {
                [void]$runs.Add(
                    [PSCustomObject]@{ Start = $runStart; End = $prevTime }
                )
                $runStart = $null
            }
        }

        $prevTime = $sample.Time
    }

    if ($null -ne $runStart -and $null -ne $prevTime) {
        [void]$runs.Add(
            [PSCustomObject]@{ Start = $runStart; End = $prevTime }
        )
    }

    return $runs.ToArray()
}

function Get-ParkStationarySpans {
    param(
        [string]$File,
        [double]$MinimumStationarySeconds
    )

    $spans = New-Object System.Collections.Generic.List[object]

    if ($MinimumStationarySeconds -le 0) {
        return $spans.ToArray()
    }

    $runs = @(Get-ParkStationaryRuns -File $File)

    foreach ($run in $runs) {
        Add-ParkSpanIfQualifying `
            $spans $run.Start $run.End $MinimumStationarySeconds
    }

    return $spans.ToArray()
}

function Get-SequenceParkedSpansByFile {
    param(
        [string[]]$Files,
        [hashtable]$RawRunsByFile,
        [hashtable]$FileMetadataCache,
        [hashtable]$Hashes,
        [hashtable]$OverlapCache,
        [double]$MinimumStationarySeconds
    )

    $resultByFile = @{}
    foreach ($file in $Files) {
        $resultByFile[[IO.Path]::GetFullPath($file)] = @()
    }

    if ($MinimumStationarySeconds -le 0 -or $Files.Count -eq 0) {
        return $resultByFile
    }

    $contribStartTimes = @{}
    $contribEndTimes = @{}
    $edgeToleranceSeconds = 1.0

    for ($i = 0; $i -lt $Files.Count; $i++) {
        $fileKey = [IO.Path]::GetFullPath($Files[$i])
        $frames = @($FileMetadataCache[$fileKey].Frames)

        if ($frames.Count -eq 0) {
            $contribStartTimes[$i] = 0.0
            $contribEndTimes[$i] = 0.0
            continue
        }

        $firstNewFrame = 0
        if ($i -gt 0) {
            $overlapInfo = $OverlapCache[$i]
            if ($null -eq $overlapInfo) {
                $overlapInfo =
                    Find-OverlapWithEventFallback `
                        $Files[$i - 1] `
                        $Files[$i] `
                        $Hashes[$i - 1] `
                        $Hashes[$i]

                $OverlapCache[$i] = $overlapInfo
            }

            if ($null -ne $overlapInfo.Result) {
                $firstNewFrame =
                    [int]($overlapInfo.Result.BStart + $overlapInfo.Result.Length)
            }
        }

        if ($firstNewFrame -ge $frames.Count) {
            $firstNewFrame = $frames.Count - 1
        }

        $contribStartTimes[$i] = $frames[$firstNewFrame].Time
        $contribEndTimes[$i] = $frames[$frames.Count - 1].Time
    }

    $nodes = New-Object System.Collections.Generic.List[object]
    $nodeIndicesByFile = @{}

    for ($i = 0; $i -lt $Files.Count; $i++) {
        $nodeIndicesByFile[$i] = New-Object System.Collections.Generic.List[int]
        $fileKey = [IO.Path]::GetFullPath($Files[$i])
        $rawRuns = @()
        if ($RawRunsByFile.ContainsKey($fileKey)) {
            $rawRuns = @($RawRunsByFile[$fileKey])
        }

        $contribStart = [double]$contribStartTimes[$i]
        $contribEnd = [double]$contribEndTimes[$i]

        foreach ($run in $rawRuns) {
            $start = [Math]::Max([double]$run.Start, $contribStart)
            $end = [Math]::Min([double]$run.End, $contribEnd)

            if ($end -le $start) {
                continue
            }

            $nodeIndex = $nodes.Count
            [void]$nodes.Add(
                [PSCustomObject]@{
                    FileIndex = $i
                    Start = $start
                    End = $end
                    ChainId = $nodeIndex
                }
            )
            [void]$nodeIndicesByFile[$i].Add($nodeIndex)
        }
    }

    for ($i = 0; $i -lt $Files.Count - 1; $i++) {
        if ($nodeIndicesByFile[$i].Count -eq 0 -or
            $nodeIndicesByFile[$i + 1].Count -eq 0) {
            continue
        }

        $nextOverlap = $OverlapCache[$i + 1]
        if ($null -eq $nextOverlap -or $null -eq $nextOverlap.Result) {
            continue
        }

        $lastNodeIndex = $nodeIndicesByFile[$i][$nodeIndicesByFile[$i].Count - 1]
        $firstNodeIndex = $nodeIndicesByFile[$i + 1][0]
        $lastNode = $nodes[$lastNodeIndex]
        $firstNode = $nodes[$firstNodeIndex]

        if ($lastNode.End -lt ($contribEndTimes[$i] - $edgeToleranceSeconds)) {
            continue
        }
        if ($firstNode.Start -gt ($contribStartTimes[$i + 1] + $edgeToleranceSeconds)) {
            continue
        }

        $oldChainId = $firstNode.ChainId
        $newChainId = $lastNode.ChainId
        if ($oldChainId -eq $newChainId) {
            continue
        }

        for ($n = 0; $n -lt $nodes.Count; $n++) {
            if ($nodes[$n].ChainId -eq $oldChainId) {
                $nodes[$n].ChainId = $newChainId
            }
        }
    }

    $chainDurations = @{}
    for ($n = 0; $n -lt $nodes.Count; $n++) {
        $chainId = $nodes[$n].ChainId
        $duration = [double]$nodes[$n].End - [double]$nodes[$n].Start
        if (-not $chainDurations.ContainsKey($chainId)) {
            $chainDurations[$chainId] = 0.0
        }
        $chainDurations[$chainId] += $duration
    }

    $qualifiedChainIds = @(
        $chainDurations.Keys |
            Where-Object { [double]$chainDurations[$_] -ge $MinimumStationarySeconds }
    )

    foreach ($chainId in $qualifiedChainIds) {
        $chainNodes = @(
            for ($n = 0; $n -lt $nodes.Count; $n++) {
                if ($nodes[$n].ChainId -eq $chainId) {
                    [PSCustomObject]@{ Index = $n; Node = $nodes[$n] }
                }
            }
        ) | Sort-Object { $_.Node.FileIndex }, { $_.Node.Start }

        if ($chainNodes.Count -eq 0) {
            continue
        }

        for ($k = 0; $k -lt $chainNodes.Count; $k++) {
            $node = $chainNodes[$k].Node
            $isFirst = ($k -eq 0)
            $isLast = ($k -eq ($chainNodes.Count - 1))

            $start = [double]$node.Start
            $end = [double]$node.End

            if ($isFirst) {
                $start += $script:ParkDetectionStartMarginSeconds
            }
            if ($isLast) {
                $end -= $script:ParkDetectionEndMarginSeconds
            }

            if ($end -le $start) {
                continue
            }

            $fileKey = [IO.Path]::GetFullPath($Files[$node.FileIndex])
            $existingSpans = @($resultByFile[$fileKey])
            $resultByFile[$fileKey] = @(
                $existingSpans +
                [PSCustomObject]@{ Start = $start; End = $end }
            )
        }
    }

    return $resultByFile
}

function Add-ParkSpanIfQualifying {
    param(
        [System.Collections.Generic.List[object]]$Spans,
        [double]$RunStart,
        $RunEnd,
        [double]$MinimumStationarySeconds
    )

    if ($null -eq $RunEnd) {
        return
    }

    $rawDuration = $RunEnd - $RunStart
    if ($rawDuration -lt $MinimumStationarySeconds) {
        return
    }

    # Never cut right up to the detected edge: pull both boundaries
    # inward so a brief passerby spike or sampling lag can never eat
    # into the moments just before the car stops or just after it
    # starts moving again.
    $cutStart = $RunStart + $script:ParkDetectionStartMarginSeconds
    $cutEnd = $RunEnd - $script:ParkDetectionEndMarginSeconds

    if ($cutEnd -le $cutStart) {
        return
    }

    [void]$Spans.Add(
        [PSCustomObject]@{ Start = $cutStart; End = $cutEnd }
    )
}

function Find-FrameIndexAtOrAfter {
    param(
        [object[]]$Frames,
        [double]$Time
    )

    for ($i = 0; $i -lt $Frames.Count; $i++) {
        if ($Frames[$i].Time -ge $Time) {
            return $i
        }
    }

    return $Frames.Count
}

# Converts second-based parked spans into the list of frame-index ranges
# that should be KEPT (i.e. the complement of the parked spans) within
# [StartFrameIndex, Frames.Count). Returns a single full range when there
# is nothing to crop.
function Get-KeptFrameRanges {
    param(
        [object[]]$Frames,
        [int]$StartFrameIndex,
        [object[]]$ParkedSpans
    )

    $ranges = New-Object System.Collections.Generic.List[object]
    $totalFrames = $Frames.Count

    if ($StartFrameIndex -ge $totalFrames) {
        return $ranges.ToArray()
    }

    $cursor = $StartFrameIndex

    foreach ($span in @($ParkedSpans | Sort-Object Start)) {

        $spanStartIndex = Find-FrameIndexAtOrAfter $Frames $span.Start
        $spanEndIndex = Find-FrameIndexAtOrAfter $Frames $span.End

        if ($spanStartIndex -ge $totalFrames -or $spanEndIndex -le $cursor) {
            continue
        }

        $effectiveSpanStart = [Math]::Max($spanStartIndex, $cursor)
        if ($effectiveSpanStart -gt $cursor) {
            [void]$ranges.Add(
                [PSCustomObject]@{
                    StartIndex = $cursor
                    EndIndex = $effectiveSpanStart
                }
            )
        }

        $cursor = [Math]::Max($cursor, $spanEndIndex)
    }

    if ($cursor -lt $totalFrames) {
        [void]$ranges.Add(
            [PSCustomObject]@{ StartIndex = $cursor; EndIndex = $totalFrames }
        )
    }

    return $ranges.ToArray()
}

# Extracts a single frame-range sub-piece of a file's video-only stream
# as an Annex-B H.264 fragment, matching the extraction style already
# used elsewhere in the pipeline (copy codec, mp4toannexb bitstream
# filter).
function New-CroppedVideoFragment {
    param(
        [string]$File,
        [object[]]$Frames,
        [object]$Range,
        [string]$TempRoot,
        [string]$BaseName
    )

    $startTime = $Frames[$Range.StartIndex].Time

    $rawPiece = Join-Path $TempRoot ($BaseName + ".avi")

    $ffmpegArguments = @(
        "-y",
        "-ss", $startTime.ToString([Globalization.CultureInfo]::InvariantCulture),
        "-i", $File
    )

    if ($Range.EndIndex -lt $Frames.Count) {
        $endTime = $Frames[$Range.EndIndex].Time
        $duration = $endTime - $startTime
        $ffmpegArguments += @(
            "-t", $duration.ToString([Globalization.CultureInfo]::InvariantCulture)
        )
    }

    $ffmpegArguments += @(
        "-map", "0:v:0",
        "-an",
        "-c:v", "copy",
        $rawPiece
    )

    Run-FFmpeg $ffmpegArguments

    $h264Piece = Join-Path $TempRoot ($BaseName + ".h264")

    Run-FFmpeg @(
        "-y",
        "-i", $rawPiece,
        "-an",
        "-c:v", "copy",
        "-bsf:v", "h264_mp4toannexb",
        "-f", "h264",
        $h264Piece
    )

    return $h264Piece
}

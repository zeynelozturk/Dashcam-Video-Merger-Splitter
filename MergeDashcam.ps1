param(
    [Parameter(ValueFromRemainingArguments = $true)]
    [string[]]$Files
)

$ErrorActionPreference = "Stop"

# ============================================================
# Settings
# ============================================================

$ffmpeg  = "ffmpeg.exe"
$ffprobe = "ffprobe.exe"

$MinimumMatchFrames = 5
$FrameRate = "29.83"

# ============================================================
# Helpers
# ============================================================

function Run-FFmpeg {
    param(
        [string[]]$Arguments
    )

    & $ffmpeg @Arguments

    if ($LASTEXITCODE -ne 0) {
        throw "FFmpeg failed with exit code $LASTEXITCODE"
    }
}

function Invoke-FFprobe {
    param(
        [string[]]$Arguments
    )

    # Some dashcam AVIs contain a broken/empty MP3 stream. FFprobe can
    # still return valid information for the requested stream (especially
    # video) but exits non-zero because it encountered that unrelated
    # broken stream. Do not treat that probe warning as a fatal error.
    $result = @(& $ffprobe @Arguments 2>$null)

    return $result
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

function Find-Overlap {
    param(
        $A,
        $B
    )

    $A = @($A)
    $B = @($B)

    $maxLength = [Math]::Min($A.Count, $B.Count)

    for ($length = $maxLength;
         $length -ge $MinimumMatchFrames;
         $length--) {

        $aStart = $A.Count - $length
        $match = $true

        for ($j = 0; $j -lt $length; $j++) {

            if ([string]$A[$aStart + $j] -ne
                [string]$B[$j]) {

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

    $A = @($A)
    $B = @($B)

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

            if ([string]$A[$aStart + $j] -ne
                [string]$B[$j]) {

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
        }
    }

    # Keep the special search narrow: only short REC -> EVT pairs.
    $previousName = [IO.Path]::GetFileName($PreviousFile)
    $currentName  = [IO.Path]::GetFileName($CurrentFile)

    $isREC = $previousName -match '^REC2_'
    $isEVT = $currentName -match '^EVT2_'

    $previousFrameCount = @($PreviousHashes).Count
    $previousDuration =
        Get-VideoDurationFromFrames $previousFrameCount

    if ($isREC -and $isEVT -and $previousDuration -le 10.0) {

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
            }
        }
    }

    return [PSCustomObject]@{
        Result = $null
        IsEventOverlap = $false
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

return $FrameCount / [double]$FrameRate
}

# ============================================================
# Validate input
# ============================================================

if ($null -eq $Files -or $Files.Count -lt 2) {

    Write-Host ""
    Write-Host "Drag two or more dashcam AVI files onto the batch file."
    Write-Host ""
    pause
    exit
}

$Files = @(
    $Files |
        ForEach-Object {
            Get-Item -LiteralPath $_
        } |
        Sort-Object LastWriteTime |
        ForEach-Object {
            $_.FullName
        }
)

foreach ($file in $Files) {

    if (-not (Test-Path -LiteralPath $file -PathType Leaf)) {
        throw "File not found: $file"
    }
}

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

$resultFile = Join-Path (
    Split-Path $Files[0] -Parent
) "merge_result.txt"

$report = New-Object System.Collections.Generic.List[string]

$report.Add("Dashcam merge result")
$report.Add("===================")
$report.Add("")

foreach ($file in $Files) {
    $report.Add("Input: $file")
}

$report.Add("")

try {

    # ========================================================
    # Detect audio
    # ========================================================

    $audioAvailable = @()
    $audioStreamIndices = @()

    foreach ($file in $Files) {

        $audioStreamIndex = Get-PCMStreamIndex $file
        $hasAudio = ($audioStreamIndex -ge 0)
        $audioAvailable += $hasAudio
        $audioStreamIndices += $audioStreamIndex

        if ($hasAudio) {
            Write-Host (
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
            Write-Host "Audio: NO   $([IO.Path]::GetFileName($file))"
            $report.Add(
                "Audio: NO   $([IO.Path]::GetFileName($file))"
            )
        }
    }

    # ========================================================
    # Generate frame hashes
    # ========================================================

    $hashes = @{}

    for ($i = 0; $i -lt $Files.Count; $i++) {

        Write-Host ""
        Write-Host "Creating frame hashes:"
        Write-Host "  $([IO.Path]::GetFileName($Files[$i]))"

        $hashes[$i] = Get-FrameHashes $Files[$i]

        Write-Host "  Frames: $(@($hashes[$i]).Count)"
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

    Write-Host ""
    Write-Host "Extracting first video..."

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

        Write-Host ""
        Write-Host "=========================================="
        Write-Host "Processing:"
        Write-Host $Files[$i]
        Write-Host "=========================================="

        $previousHashes = $hashes[$i - 1]
        $currentHashes  = $hashes[$i]

        $overlapInfo =
            Find-OverlapWithEventFallback `
                $Files[$i - 1] `
                $Files[$i] `
                $previousHashes `
                $currentHashes

        $overlap = $overlapInfo.Result

        # ----------------------------------------------------
        # NO OVERLAP
        # ----------------------------------------------------

        if ($null -eq $overlap) {

            Write-Host ""
            Write-Host "WARNING: No overlap found."
            Write-Host "Appending entire file."

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

            continue
        }

        # ----------------------------------------------------
        # OVERLAP FOUND
        # ----------------------------------------------------

        Write-Host ""
        if ($overlapInfo.IsEventOverlap) {
            Write-Host (
                "Event overlap: $($overlap.Length) frames " +
                "(REC tail is at start of EVT)"
            )
        }
        else {
            Write-Host "Overlap: $($overlap.Length) frames"
        }

        $report.Add("")
        if ($overlapInfo.IsEventOverlap) {
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

        $frames = @(Get-VideoFrames $Files[$i])

        Write-Host "Current file frames: $($frames.Count)"
        Write-Host "Overlap starts at current-file frame: $($overlap.BStart)"
        Write-Host "Overlap length: $($overlap.Length)"

        $firstNewFrame =
            $overlap.BStart + $overlap.Length

        Write-Host "First new frame: $firstNewFrame"

        # ----------------------------------------------------
        # Entire file is overlap
        # ----------------------------------------------------

        if ($firstNewFrame -ge $frames.Count) {

            Write-Host ""
            Write-Host "Entire current file is overlap."
            Write-Host "Nothing will be appended."

            $report.Add(
                "Entire file was overlap; nothing appended."
            )

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

        Write-Host ""
        Write-Host "First new frame : $firstNewFrame"
        Write-Host "Next I-frame    : $keyFrame"
        Write-Host "Transition frames: $transitionFrames"
        Write-Host "Transition start: $startTime"
        Write-Host "Next I-frame    : $keyTime"

        # ----------------------------------------------------
        # Re-encode tiny transition
        # ----------------------------------------------------

        if ($transitionFrames -gt 0) {

            $transition = Join-Path $tempRoot (
                "transition_{0:D3}.mp4" -f $i
            )

            $duration = $keyTime - $startTime

            Write-Host ""
            Write-Host (
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
                $transition
            )

            $transitionH264 = Join-Path $tempRoot (
                "transition_{0:D3}.h264" -f $i
            )

            Run-FFmpeg @(
                "-y",
                "-i", $transition,
                "-an",
                "-c:v", "copy",
                "-bsf:v", "h264_mp4toannexb",
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

        Write-Host ""
        Write-Host "Copying original H.264 from I-frame onward..."

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
    }

    # ========================================================
    # Concatenate raw H264
    # ========================================================

    $combinedH264 =
        Join-Path $tempRoot "combined.h264"

    Write-Host ""
    Write-Host "Concatenating H.264 bitstreams..."

    $inputFiles = $videoPieces | ForEach-Object {
        '"' + $_ + '"'
    }

    cmd.exe /c (
        'copy /b ' +
        ($inputFiles -join '+') +
        ' "' + $combinedH264 + '"'
    )

    if ($LASTEXITCODE -ne 0) {
        throw "Could not concatenate H.264 streams."
    }

    # ========================================================
    # Create video-only merged AVI
    # ========================================================

    $firstDirectory =
        Split-Path $Files[0] -Parent

    $firstName =
        [IO.Path]::GetFileNameWithoutExtension($Files[0])

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

Write-Host ""
Write-Host "Preparing audio..."

$audioParts =
    New-Object System.Collections.Generic.List[string]

# --------------------------------------------------------
# Helper: create one audio segment
# --------------------------------------------------------

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

        Write-Host (
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

        Run-FFmpeg @(
            "-y",
            "-ss", $startText,
            "-i", $InputFile,
            "-map", "0:$AudioStreamIndex",
            "-vn",
            "-sn",
            "-dn",
            "-af",
            "apad=whole_dur=$durationText,atrim=duration=$durationText",
            "-t", $durationText,
            "-c:a", "pcm_s16le",
            $OutputFile
        )
    }
    else {

        Write-Host (
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

    $overlapInfo =
        Find-OverlapWithEventFallback `
            $Files[$i - 1] `
            $Files[$i] `
            $previousHashes `
            $currentHashes

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

        Write-Host (
            "Audio: " +
            [IO.Path]::GetFileName($Files[$i]) +
            " contributes no video frames."
        )

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

        $frames =
            @(Get-VideoFrames $Files[$i])

        if ($firstNewFrame -ge $frames.Count) {
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

    Write-Host ""
    Write-Host "Audio successfully added."
}
else {

    Write-Host ""
    Write-Host "No audio segments were created."

    $report.Add("")
    $report.Add("No audio segments were created.")
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

    Write-Host ""
    Write-Host "Temporary files:"
    Write-Host $tempRoot
    Write-Host ""

    # Keep temporary files while testing.
    #
    # Once everything is confirmed working, change to:
    #
    # Remove-Item -LiteralPath $tempRoot -Recurse -Force

    pause
}
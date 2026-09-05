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

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

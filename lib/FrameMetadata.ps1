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

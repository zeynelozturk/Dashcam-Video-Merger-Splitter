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
    $preferredTempFullPath = [IO.Path]::GetFullPath($TempDirectory)
    $preferredTempDrive = Get-DriveSpaceSnapshot -Path $preferredTempFullPath

    $tempCandidates =
        New-Object System.Collections.Generic.List[object]

    [void]$tempCandidates.Add(
        [PSCustomObject]@{
            Root = $preferredTempDrive.Root
            FreeBytes = $preferredTempDrive.FreeBytes
            TempBaseDirectory = $preferredTempFullPath
            IsPreferred = $true
        }
    )

    $fixedDrives = @(
        [System.IO.DriveInfo]::GetDrives() |
            Where-Object {
                $_.IsReady -and
                $_.DriveType -eq [System.IO.DriveType]::Fixed
            }
    )

    foreach ($drive in $fixedDrives) {
        $candidateRoot = $drive.Name.TrimEnd('\\')
        if ($candidateRoot -eq $preferredTempDrive.Root) {
            continue
        }

        [void]$tempCandidates.Add(
            [PSCustomObject]@{
                Root = $candidateRoot
                FreeBytes = [int64]$drive.AvailableFreeSpace
                TempBaseDirectory = Join-Path $drive.Name "DashcamVideoMergerTemp"
                IsPreferred = $false
            }
        )
    }

    $attemptLines =
        New-Object System.Collections.Generic.List[string]

    $selectedCandidate = $null
    $outputError = $null

    foreach ($candidate in $tempCandidates) {
        $requiredTempOnThisDrive = [int64]$estimate.RequiredTempBytes

        if ($candidate.Root -eq $targetDrive.Root) {
            $requiredTempOnThisDrive += [int64]$estimate.RequiredTargetBytes
        }

        $outputRequirementMet = $true
        if ($candidate.Root -ne $targetDrive.Root) {
            $outputRequirementMet = (
                $targetDrive.FreeBytes -ge $estimate.RequiredTargetBytes
            )
        }

        $tempRequirementMet = (
            $candidate.FreeBytes -ge $requiredTempOnThisDrive
        )

        $attemptLabel = $candidate.Root
        if ($candidate.IsPreferred) {
            $attemptLabel += " (preferred TEMP)"
        }

        [void]$attemptLines.Add(
            "- " +
            $attemptLabel +
            ": need " +
            (Format-ByteSize $requiredTempOnThisDrive) +
            ", available " +
            (Format-ByteSize $candidate.FreeBytes)
        )

        if ($outputRequirementMet -and $tempRequirementMet) {
            $selectedCandidate = $candidate
            break
        }

        if ($candidate.Root -ne $targetDrive.Root -and -not $outputRequirementMet) {
            $outputError = (
                "Not enough free disk space on output drive " +
                $targetDrive.Root +
                ". Required " +
                (Format-ByteSize $estimate.RequiredTargetBytes) +
                ", available " +
                (Format-ByteSize $targetDrive.FreeBytes) +
                "."
            )
        }
    }

    if ($null -eq $selectedCandidate) {
        $messageParts =
            New-Object System.Collections.Generic.List[string]

        $outputRequirementMetGlobally = (
            $targetDrive.FreeBytes -ge $estimate.RequiredTargetBytes
        )

        if (-not $outputRequirementMetGlobally) {
            if (-not [string]::IsNullOrWhiteSpace($outputError)) {
                [void]$messageParts.Add($outputError)
            }
            else {
                [void]$messageParts.Add(
                    "Not enough free disk space on output drive " +
                    $targetDrive.Root +
                    ". Required " +
                    (Format-ByteSize $estimate.RequiredTargetBytes) +
                    ", available " +
                    (Format-ByteSize $targetDrive.FreeBytes) +
                    "."
                )
            }
        }
        else {
            [void]$messageParts.Add(
                "No usable temp location was found after checking preferred TEMP " +
                "and all ready fixed drives."
            )
        }

        [void]$messageParts.Add(
            "Output drive " +
            $targetDrive.Root +
            ": need " +
            (Format-ByteSize $estimate.RequiredTargetBytes) +
            ", available " +
            (Format-ByteSize $targetDrive.FreeBytes)
        )

        [void]$messageParts.Add("Temp drive attempts:")
        foreach ($line in $attemptLines) {
            [void]$messageParts.Add($line)
        }

        throw ($messageParts -join [Environment]::NewLine)
    }

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
        $selectedCandidate.Root +
        "): " +
        (Format-ByteSize $estimate.RequiredTempBytes) +
        " (available " +
        (Format-ByteSize $selectedCandidate.FreeBytes) +
        ")"
    )

    if (-not $selectedCandidate.IsPreferred) {
        Write-Host (
            "- TEMP fallback selected: " +
            $selectedCandidate.TempBaseDirectory
        )
    }

    return [PSCustomObject]@{
        SelectedTempBaseDirectory = $selectedCandidate.TempBaseDirectory
        SelectedTempDriveRoot = $selectedCandidate.Root
        UsedTempFallback = (-not $selectedCandidate.IsPreferred)
    }
}

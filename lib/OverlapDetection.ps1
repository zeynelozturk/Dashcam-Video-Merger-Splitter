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

        # Next file can be REC (normal loop resumes) or EVT (another event
        # fires soon after) — either way, a fully-contained candidate is
        # only skipped once the bypass overlap check below confirms the
        # previous/next files reconnect cleanly on their own.
        $isDeepflyContainedCandidate = (
            $previousName.StartsWith(
                $EventFilePrefix,
                [StringComparison]::OrdinalIgnoreCase
            ) -and
            $candidateName.StartsWith(
                $RecordingFilePrefix,
                [StringComparison]::OrdinalIgnoreCase
            ) -and
            (
                $nextName.StartsWith(
                    $RecordingFilePrefix,
                    [StringComparison]::OrdinalIgnoreCase
                ) -or
                $nextName.StartsWith(
                    $EventFilePrefix,
                    [StringComparison]::OrdinalIgnoreCase
                )
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

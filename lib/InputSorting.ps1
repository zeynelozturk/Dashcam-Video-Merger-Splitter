function Convert-DraggedFileList {
    param(
        [string]$Text
    )

    $trimmedText = [string]$Text
    if (-not [string]::IsNullOrWhiteSpace($trimmedText)) {
        $trimmedText = $trimmedText.Trim()
        if (Test-Path -LiteralPath $trimmedText) {
            return @($trimmedText)
        }
    }

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

function Resolve-PrimaryInputFiles {
    param(
        [string[]]$InputPaths
    )

    $cleanInputPaths = @(
        $InputPaths |
            Where-Object {
                -not [string]::IsNullOrWhiteSpace([string]$_)
            }
    )

    if ($cleanInputPaths.Count -eq 0) {
        throw "No input paths were provided."
    }

    $items = @(
        $cleanInputPaths |
            ForEach-Object {
                Get-Item -LiteralPath ([string]$_)
            }
    )

    $folders = @(
        $items |
            Where-Object {
                $_.PSIsContainer
            }
    )

    $files = @(
        $items |
            Where-Object {
                -not $_.PSIsContainer
            }
    )

    if ($folders.Count -gt 0 -and $files.Count -gt 0) {
        throw (
            "Do not mix folders and files in the initial selection. " +
            "Select either one folder or multiple files."
        )
    }

    if ($folders.Count -gt 1) {
        throw "Please select only one folder."
    }

    if ($folders.Count -eq 1) {
        $folderPath = $folders[0].FullName
        $allowedExtensions = @(".avi", ".mp4", ".mov", ".mkv")

        $videoFiles = @(
            Get-ChildItem -LiteralPath $folderPath -File |
                Where-Object {
                    $allowedExtensions -contains $_.Extension.ToLowerInvariant()
                } |
                Sort-Object Name
        )

        if ($videoFiles.Count -lt 2) {
            throw (
                "The selected folder contains fewer than 2 supported video files " +
                "(.avi, .mp4, .mov, .mkv)."
            )
        }

        return [PSCustomObject]@{
            Files = @($videoFiles | ForEach-Object { $_.FullName })
            InputMode = "Folder"
            SourceFolder = $folderPath
            IgnoredCount = 0
        }
    }

    $fileFullPaths = @(
        $files |
            ForEach-Object {
                $_.FullName
            }
    )

    if ($fileFullPaths.Count -lt 2) {
        throw "At least two files are required."
    }

    return [PSCustomObject]@{
        Files = $fileFullPaths
        InputMode = "Files"
        SourceFolder = (Split-Path $fileFullPaths[0] -Parent)
        IgnoredCount = 0
    }
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
                    $behaviorChoice = Read-HostWithSpacing "Select [1/2] (press Enter for 1)"

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
                            $choice = Read-HostWithSpacing "Select [1/2] (press Enter for 1)"

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
                            $choice = Read-HostWithSpacing "Select [1/2] (press Enter for 1)"

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
                    $choice = Read-HostWithSpacing "Select [1/2] (press Enter for 1)"

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

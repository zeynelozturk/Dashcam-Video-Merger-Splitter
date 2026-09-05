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

function Read-HostWithSpacing {
    param(
        [string]$Prompt
    )

    Write-Host ""
    return Read-Host $Prompt
}

function Wait-ForUserExit {
    param(
        [string]$Prompt = "Press Enter to finish."
    )

    try {
        [void](Read-HostWithSpacing $Prompt)
    }
    catch {
    }
}

function Get-FfmpegSetupHelpText {
    return (
        "Supported setups: " +
        "(1) Place ffmpeg.exe and ffprobe.exe in .\\ffmpeg\\ next to MergeDashcam.ps1, " +
        "or (2) install both in PATH, " +
        "or (3) set FFmpegPath and FFprobePath in MergeDashcam.config.psd1."
    )
}

function Resolve-ExecutablePath {
    param(
        [string]$ConfiguredPath,
        [string]$ExecutableFileName,
        [string]$ToolLabel,
        [string]$ConfigSettingName
    )

    $bundledCandidate = Join-Path $PSScriptRoot (
        Join-Path "ffmpeg" $ExecutableFileName
    )

    if (Test-Path -LiteralPath $bundledCandidate -PathType Leaf) {
        return (Resolve-Path -LiteralPath $bundledCandidate).Path
    }

    if ([string]::IsNullOrWhiteSpace($ConfiguredPath)) {
        throw (
            "$ConfigSettingName cannot be empty in: $configPath" +
            [Environment]::NewLine +
            (Get-FfmpegSetupHelpText)
        )
    }

    $candidate = [string]$ConfiguredPath
    $appearsPathLike = (
        $candidate.IndexOf("\\") -ge 0 -or
        $candidate.IndexOf("/") -ge 0 -or
        $candidate.IndexOf(":") -ge 0
    )

    if ($appearsPathLike) {
        if (-not [IO.Path]::IsPathRooted($candidate)) {
            $candidate = Join-Path $PSScriptRoot $candidate
        }

        if (-not (Test-Path -LiteralPath $candidate -PathType Leaf)) {
            throw (
                "$ToolLabel was not found at configured path '$ConfiguredPath'. " +
                "Update $ConfigSettingName in MergeDashcam.config.psd1." +
                [Environment]::NewLine +
                (Get-FfmpegSetupHelpText)
            )
        }

        return (Resolve-Path -LiteralPath $candidate).Path
    }

    $resolvedCommand = Get-Command `
        -Name $candidate `
        -CommandType Application `
        -ErrorAction SilentlyContinue |
            Select-Object -First 1

    if ($null -eq $resolvedCommand) {
        throw (
            "$ToolLabel executable '$ConfiguredPath' was not found in PATH. " +
            "Install $ToolLabel or set $ConfigSettingName to the full executable path " +
            "in MergeDashcam.config.psd1." +
            [Environment]::NewLine +
            (Get-FfmpegSetupHelpText)
        )
    }

    return [string]$resolvedCommand.Source
}

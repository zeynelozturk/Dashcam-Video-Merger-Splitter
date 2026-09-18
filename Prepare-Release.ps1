param(
    [string]$RootPath = (Split-Path -Parent $MyInvocation.MyCommand.Path),
    [string]$OutputPath = (Join-Path (Split-Path -Parent $MyInvocation.MyCommand.Path) "Dashcam-Video-Merger-and-Splitter-Release.zip")
)

$ErrorActionPreference = "Stop"

$root = (Resolve-Path -LiteralPath $RootPath).Path
$scriptFile = $PSCommandPath
if ([string]::IsNullOrWhiteSpace($scriptFile)) {
    $scriptFile = $MyInvocation.MyCommand.Path
}

if (-not (Test-Path -LiteralPath $root -PathType Container)) {
    throw "Root path does not exist: $root"
}

$parent = Split-Path -Parent $OutputPath
if (-not [string]::IsNullOrWhiteSpace($parent) -and -not (Test-Path -LiteralPath $parent -PathType Container)) {
    New-Item -ItemType Directory -Path $parent -Force | Out-Null
}

if (Test-Path -LiteralPath $OutputPath -PathType Leaf) {
    Remove-Item -LiteralPath $OutputPath -Force
}

$itemsToPack = @()
foreach ($item in Get-ChildItem -LiteralPath $root -Force) {
    $name = $item.Name

    if ($item.FullName -eq $scriptFile) {
        continue
    }

    if ($name -eq "Prepare Release.zip.cmd") {
        continue
    }

    if ($name -eq ".git") {
        continue
    }

    if ($name -in @(".gitignore", ".gitattributes", ".gitmodules")) {
        continue
    }

    if ($item.FullName -eq (Resolve-Path -LiteralPath $OutputPath -ErrorAction SilentlyContinue).Path) {
        continue
    }

    $itemsToPack += $item
}

if ($itemsToPack.Count -eq 0) {
    throw "No files were selected to include in the release archive."
}

$tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("dashcam-release-" + [guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Path $tempRoot -Force | Out-Null

try {
    foreach ($item in $itemsToPack) {
        $destinationPath = Join-Path $tempRoot $item.Name
        if ($item.PSIsContainer) {
            Copy-Item -LiteralPath $item.FullName -Destination $destinationPath -Recurse -Force
        }
        else {
            Copy-Item -LiteralPath $item.FullName -Destination $destinationPath -Force
        }
    }

    Get-ChildItem -LiteralPath $tempRoot -Filter "ffplay.exe" -File -Recurse |
        Remove-Item -Force

    if (Test-Path -LiteralPath $OutputPath -PathType Leaf) {
        Remove-Item -LiteralPath $OutputPath -Force
    }

    Compress-Archive -Path (Join-Path $tempRoot "*") -DestinationPath $OutputPath -Force

    Write-Host "Release archive created: $OutputPath"
    Write-Host "Included items: $($itemsToPack.Count)"
}
finally {
    if (Test-Path -LiteralPath $tempRoot -PathType Container) {
        Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}

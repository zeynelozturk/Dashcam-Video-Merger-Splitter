function Select-OutputDirectory {
    param(
        [string]$SourceDirectory
    )

    $registryPath = "HKCU:\Software\DashcamVideoMergerSplitter"
    $lastDirectory = $null

    try {
        $lastDirectory = (Get-ItemProperty `
            -Path $registryPath `
            -Name LastOutputDirectory `
            -ErrorAction Stop
        ).LastOutputDirectory
    }
    catch {
        $lastDirectory = $null
    }

    $lastDirectoryIsValid = (
        -not [string]::IsNullOrWhiteSpace($lastDirectory) -and
        (Test-Path -LiteralPath $lastDirectory -PathType Container)
    )

    Write-Host ""
    Write-Host "Output folder:"
    if ([string]::IsNullOrWhiteSpace($lastDirectory)) {
        Write-Host "[1] Last folder (default): not set"
    }
    elseif ($lastDirectoryIsValid) {
        Write-Host "[1] Last folder (default): $lastDirectory"
    }
    else {
        Write-Host "[1] Last folder (default): $lastDirectory (not available)"
    }
    Write-Host "[2] Same folder as videos"
    Write-Host "[3] Browse..."

    $persistAsLastOutputDirectory = $true

    while ($true) {
        $choice = Read-HostWithSpacing "Select [1/2/3] (press Enter for 1)"

        if ([string]::IsNullOrWhiteSpace($choice) -or $choice -eq "1") {
            if ($lastDirectoryIsValid) {
                $selectedDirectory = [IO.Path]::GetFullPath($lastDirectory)
            }
            else {
                $selectedDirectory = $SourceDirectory
                Write-Host "No valid last folder found. Using the folder containing the videos."
            }
            break
        }

        if ($choice -eq "2") {
            $selectedDirectory = Join-Path $SourceDirectory "Merged Videos"
            $persistAsLastOutputDirectory = $false
            break
        }

        if ($choice -eq "3") {
            $selectedDirectory = $null

            for (
                $attempt = 0;
                $attempt -lt 1;
                $attempt++
            ) {
                $selectedDirectory = & powershell.exe -NoProfile -STA -Command `
                    "Add-Type -AssemblyName System.Windows.Forms; `$dialog = New-Object System.Windows.Forms.FolderBrowserDialog; `$dialog.Description = 'Choose output folder'; if (`$dialog.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) { `$dialog.SelectedPath }"
            }

            if (-not [string]::IsNullOrWhiteSpace($selectedDirectory)) {
                break
            }

            Write-Host "No folder selected. Using the folder containing the videos."
            $selectedDirectory = $SourceDirectory
            break
        }

        Write-Host "Please enter 1, 2, or 3."
    }

    if (-not (Test-Path -LiteralPath $selectedDirectory -PathType Container)) {
        New-Item -ItemType Directory -Path $selectedDirectory -Force | Out-Null
    }

    $selectedDirectory = [IO.Path]::GetFullPath($selectedDirectory)

    if ($persistAsLastOutputDirectory) {
        try {
            New-Item -Path $registryPath -Force | Out-Null
            Set-ItemProperty `
                -Path $registryPath `
                -Name LastOutputDirectory `
                -Value $selectedDirectory
        }
        catch {
            Write-Host "Could not save the last output folder."
        }
    }

    return $selectedDirectory
}

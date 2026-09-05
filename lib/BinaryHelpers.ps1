function Join-BinaryFiles {
    param(
        [string[]]$InputFiles,
        [string]$OutputFile
    )

    if ($null -eq $InputFiles -or $InputFiles.Count -eq 0) {
        throw "No input files were provided for binary concatenation."
    }

    $bufferSize = 4MB
    $buffer = New-Object byte[] $bufferSize

    $outputStream = [System.IO.File]::Open(
        $OutputFile,
        [System.IO.FileMode]::Create,
        [System.IO.FileAccess]::Write,
        [System.IO.FileShare]::None
    )

    try {
        foreach ($inputFile in $InputFiles) {
            $inputStream = [System.IO.File]::Open(
                $inputFile,
                [System.IO.FileMode]::Open,
                [System.IO.FileAccess]::Read,
                [System.IO.FileShare]::Read
            )

            try {
                while ($true) {
                    $readCount = $inputStream.Read($buffer, 0, $buffer.Length)

                    if ($readCount -le 0) {
                        break
                    }

                    $outputStream.Write($buffer, 0, $readCount)
                }
            }
            finally {
                $inputStream.Dispose()
            }
        }
    }
    finally {
        $outputStream.Dispose()
    }
}

param(
    [string]$LogPath = "scene.log",
    [double]$Threshold = 0.06,
    [double]$MinDurationSec = 5
)

$lines = Get-Content $LogPath
$rows = @()
for ($i = 0; $i -lt $lines.Count; $i += 2) {
    $t = [double]($lines[$i] -replace '.*pts_time:', '')
    $v = [double]($lines[$i + 1] -replace '.*=', '')
    $rows += [PSCustomObject]@{ t = $t; v = $v }
}

# Find contiguous runs where value stays <= Threshold
$spans = @()
$runStart = $null
$prevT = $null
foreach ($r in $rows) {
    if ($r.v -le $Threshold) {
        if ($null -eq $runStart) { $runStart = $r.t }
    } else {
        if ($null -ne $runStart) {
            $dur = $prevT - $runStart
            if ($dur -ge $MinDurationSec) {
                $spans += [PSCustomObject]@{ Start = $runStart; End = $prevT; Duration = $dur }
            }
            $runStart = $null
        }
    }
    $prevT = $r.t
}
if ($null -ne $runStart) {
    $dur = $prevT - $runStart
    if ($dur -ge $MinDurationSec) {
        $spans += [PSCustomObject]@{ Start = $runStart; End = $prevT; Duration = $dur }
    }
}

function Fmt($sec) {
    $ts = [TimeSpan]::FromSeconds($sec)
    return $ts.ToString("mm\:ss")
}

Write-Host "Low-motion spans (threshold<=$Threshold, min duration $MinDurationSec s):"
$spans | ForEach-Object {
    "{0} - {1}  (dur {2:N1}s)" -f (Fmt $_.Start), (Fmt $_.End), $_.Duration
}

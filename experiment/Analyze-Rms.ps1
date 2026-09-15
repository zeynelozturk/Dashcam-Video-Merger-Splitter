param(
    [string]$LogPath = "rms.log"
)

$lines = Get-Content $LogPath
$rows = @()
for ($i = 0; $i -lt $lines.Count; $i += 2) {
    $t = [double]($lines[$i] -replace '.*pts_time:', '')
    $rms = [double]($lines[$i + 1] -replace '.*=', '')
    $rows += [PSCustomObject]@{ t = $t; rms = $rms }
}

Write-Host "Total seconds logged: $($rows.Count)"

Write-Host "`n--- Stop 1 (10:05-10:11 = 605-611s), context 590-625 ---"
$rows | Where-Object { $_.t -ge 590 -and $_.t -le 625 } | Format-Table -AutoSize

Write-Host "`n--- Stop 2 (13:29-13:46 = 809-826s), context 795-835 ---"
$rows | Where-Object { $_.t -ge 795 -and $_.t -le 835 } | Format-Table -AutoSize

Write-Host "`n--- Overall stats ---"
$stop1 = $rows | Where-Object { $_.t -ge 605 -and $_.t -le 611 }
$stop2 = $rows | Where-Object { $_.t -ge 809 -and $_.t -le 826 }
$driving = $rows | Where-Object { ($_.t -ge 500 -and $_.t -lt 605) -or ($_.t -gt 611 -and $_.t -lt 809) -or ($_.t -gt 826 -and $_.t -le 900) }

"Stop1 avg RMS: {0:N2} (n={1})" -f (($stop1.rms | Measure-Object -Average).Average), $stop1.Count
"Stop2 avg RMS: {0:N2} (n={1})" -f (($stop2.rms | Measure-Object -Average).Average), $stop2.Count
"Driving avg RMS: {0:N2} (n={1})" -f (($driving.rms | Measure-Object -Average).Average), $driving.Count

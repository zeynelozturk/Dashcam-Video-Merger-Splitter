param(
    [string]$LogPath,
    [string]$MetricName = "value",
    [double[]]$Stop1Range = @(605, 611),
    [double[]]$Stop2Range = @(809, 826)
)

$lines = Get-Content $LogPath
$rows = @()
for ($i = 0; $i -lt $lines.Count; $i += 2) {
    $t = [double]($lines[$i] -replace '.*pts_time:', '')
    $v = [double]($lines[$i + 1] -replace '.*=', '')
    $rows += [PSCustomObject]@{ t = $t; v = $v }
}

Write-Host "Total samples: $($rows.Count), metric=$MetricName"

$stop1 = $rows | Where-Object { $_.t -ge $Stop1Range[0] -and $_.t -le $Stop1Range[1] }
$stop2 = $rows | Where-Object { $_.t -ge $Stop2Range[0] -and $_.t -le $Stop2Range[1] }
$driving = $rows | Where-Object {
    ($_.t -ge ($Stop1Range[0] - 120) -and $_.t -lt $Stop1Range[0]) -or
    ($_.t -gt $Stop1Range[1] -and $_.t -lt $Stop2Range[0]) -or
    ($_.t -gt $Stop2Range[1] -and $_.t -le ($Stop2Range[1] + 120))
}

function Stats($set, $label) {
    $avg = ($set.v | Measure-Object -Average).Average
    $max = ($set.v | Measure-Object -Maximum).Maximum
    $min = ($set.v | Measure-Object -Minimum).Minimum
    "{0}: n={1} avg={2:N4} min={3:N4} max={4:N4}" -f $label, $set.Count, $avg, $min, $max
}

Stats $stop1 "Stop1 (parked)"
Stats $stop2 "Stop2 (parked)"
Stats $driving "Driving (context)"

Write-Host "`n--- Stop1 detail ---"
$stop1Ctx = $rows | Where-Object { $_.t -ge ($Stop1Range[0]-10) -and $_.t -le ($Stop1Range[1]+10) }
$stop1Ctx | Format-Table -AutoSize

Write-Host "`n--- Stop2 detail (sampled) ---"
$stop2Ctx = $rows | Where-Object { $_.t -ge ($Stop2Range[0]-10) -and $_.t -le ($Stop2Range[1]+10) }
$stop2Ctx | Format-Table -AutoSize

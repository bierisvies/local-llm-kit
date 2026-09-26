<#
.SYNOPSIS
  Adds "LLM pause" / "LLM resume" shortcuts to the desktop and starts the game watcher at logon
  (pauses the local LLM while a game runs). Safe to re-run.
#>
param([string]$PauseName = 'LLM pause', [string]$ResumeName = 'LLM resume')
$control = Join-Path $PSScriptRoot 'llm-control.ps1'
$watch = Join-Path $PSScriptRoot 'game-watch.ps1'
$desktop = [Environment]::GetFolderPath('Desktop')
$shell = New-Object -ComObject WScript.Shell

foreach ($s in @(@($PauseName, 'pause', 'Free the GPU: stop the local LLM (e.g. before gaming)', 110),
                 @($ResumeName, 'resume', 'Start the local LLM again', 137))) {
  $lnk = $shell.CreateShortcut((Join-Path $desktop "$($s[0]).lnk"))
  $lnk.TargetPath = 'powershell.exe'
  $lnk.Arguments = "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$control`" -Action $($s[1])"
  $lnk.Description = $s[2]
  $lnk.IconLocation = "$env:SystemRoot\System32\shell32.dll,$($s[3])"
  $lnk.WindowStyle = 7   # minimized
  $lnk.Save()
}

$action = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$watch`""
$trigger = New-ScheduledTaskTrigger -AtLogOn -User "$env:USERDOMAIN\$env:USERNAME"
$settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit ([TimeSpan]::Zero) -MultipleInstances IgnoreNew
Register-ScheduledTask -TaskName 'Local LLM game watch' -Action $action -Trigger $trigger -Settings $settings -Force | Out-Null
Start-ScheduledTask -TaskName 'Local LLM game watch'
Write-Host "Desktop shortcuts '$PauseName' and '$ResumeName' created; game watcher running (task 'Local LLM game watch')."

<#
.SYNOPSIS
  Pauses the local LLM while a game runs and resumes it when the game closes.
  Runs in the background at logon (registered by install-pause-controls.ps1).
  Games: "gameProcesses" in server\settings.json (process names without .exe), or the defaults below.
  Only resumes pauses it made itself: a manual pause (desktop shortcut) stays until you resume it.
#>
$ErrorActionPreference = 'SilentlyContinue'
$control = Join-Path $PSScriptRoot 'llm-control.ps1'
$flag = Join-Path $env:LOCALAPPDATA 'local-llm\paused.flag'
$defaults = @('League of Legends', 'VALORANT-Win64-Shipping', 'cs2', 'r5apex', 'FortniteClient-Win64-Shipping',
              'RocketLeague', 'Overwatch', 'eldenring', 'GTA5', 'bg3', 'Cyberpunk2077')

while ($true) {
  $cfg = Get-Content (Join-Path $PSScriptRoot 'settings.json') -Raw | ConvertFrom-Json
  $games = if ($cfg.gameProcesses) { @($cfg.gameProcesses) } else { $defaults }
  $gameRunning = [bool](Get-Process -Name $games -ErrorAction SilentlyContinue)
  $pause = if (Test-Path $flag) { (Get-Content $flag -Raw).Trim() } else { '' }

  if ($gameRunning -and -not $pause) { & $control -Action pause -Auto -Quiet }
  elseif (-not $gameRunning -and $pause -eq 'auto') { & $control -Action resume -Quiet }
  Start-Sleep -Seconds 5
}

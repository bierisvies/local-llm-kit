<#
.SYNOPSIS
  Pause or resume the local llama-server, e.g. to free the GPU for a game.
  pause : stops the server immediately (VRAM/RAM freed, a running task is aborted) and sets a "paused" flag,
          so neither the logon autostart nor the delegation tool starts/uses it.
  resume: clears the flag and starts the server again (~20-30 s).
  status: prints the current state.
  -Auto marks a pause as made by game-watch.ps1, which then also resumes it; a manual pause is never
  resumed automatically.
#>
param(
  [Parameter(Mandatory)][ValidateSet('pause', 'resume', 'status')][string]$Action,
  [switch]$Auto,
  [switch]$Quiet    # no popup (used by game-watch.ps1)
)
$flagDir = Join-Path $env:LOCALAPPDATA 'local-llm'
$flag = Join-Path $flagDir 'paused.flag'
$startScript = Join-Path $PSScriptRoot 'start-llama.ps1'

function Notify($text) {
  if ($Quiet) { return }
  Add-Type -AssemblyName System.Windows.Forms
  [void][System.Windows.Forms.MessageBox]::Show($text, 'Local LLM')
}
function Server-Task {
  # The logon task that runs this kit's start script (its name differs per machine).
  Get-ScheduledTask -ErrorAction SilentlyContinue | Where-Object {
    $_.Actions | Where-Object { $_.Arguments -like "*$startScript*" }
  } | Select-Object -First 1
}

switch ($Action) {
  'pause' {
    New-Item -ItemType Directory -Force $flagDir | Out-Null
    Set-Content $flag $(if ($Auto) { 'auto' } else { 'manual' })
    $p = Get-Process llama-server -ErrorAction SilentlyContinue
    if ($p) { $p | Stop-Process -Force; $p | Wait-Process -Timeout 10 -ErrorAction SilentlyContinue }
    Notify 'Local LLM paused: the GPU is free. New tasks go to other PCs until you resume.'
  }
  'resume' {
    Remove-Item $flag -ErrorAction SilentlyContinue
    if (-not (Get-Process llama-server -ErrorAction SilentlyContinue)) {
      $task = Server-Task
      if ($task) { Start-ScheduledTask -TaskName $task.TaskName -TaskPath $task.TaskPath }
      else { Start-Process powershell.exe -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $startScript) -WindowStyle Hidden }
    }
    Notify 'Local LLM resumed. It is ready in about 20-30 seconds.'
  }
  'status' {
    $state = if (Test-Path $flag) { "paused ($(Get-Content $flag))" } elseif (Get-Process llama-server -ErrorAction SilentlyContinue) { 'running' } else { 'stopped' }
    Write-Output $state
  }
}

# Starts llama-server with the profile chosen by setup.ps1. Values come from server\settings.json.
# No 'Stop' error preference: llama-server logs to stderr, which Windows PowerShell 5.1 would treat as a fatal error.
$cfg = Get-Content (Join-Path $PSScriptRoot 'settings.json') -Raw | ConvertFrom-Json

$llamaArgs = @('-m', $cfg.model, '--alias', $cfg.alias, '--host', $cfg.host, '--port', $cfg.port, '-ngl', 'all', '-fa', 'on')
if ($cfg.mmproj) { $llamaArgs += @('--mmproj', $cfg.mmproj) }

# GPU/RAM split: a measured -ncmoe (MoE expert layers kept in RAM), or llama.cpp's automatic fit
# with 2.5 GiB left free for Windows/desktop apps (less headroom makes the model spill into shared memory).
if ($cfg.ncmoe -ne '') { $llamaArgs += @('-ncmoe', $cfg.ncmoe, '-fit', 'off') }
else { $llamaArgs += @('-fit', 'on', '--fit-target', '2560') }

# Q4 KV cache keeps long context small; YaRN only when the context exceeds what the model was trained on.
$llamaArgs += @('-ctk', 'q4_0', '-ctv', 'q4_0', '-c', $cfg.context, '-b', '2048', '-ub', '1024', '-t', $cfg.threads, '-np', '1')
if ([int]$cfg.context -gt [int]$cfg.trainContext) {
  $scale = [math]::Round([int]$cfg.context / [int]$cfg.trainContext, 2)
  $llamaArgs += @('--rope-scaling', 'yarn', '--rope-scale', "$scale", '--yarn-orig-ctx', $cfg.trainContext)
}

$llamaArgs += @(
  '--cache-prompt', '--jinja', '-n', '32768',
  '--reasoning', 'on', '--reasoning-effort', 'high', '--reasoning-budget', '32768',
  # Qwen's recommended sampling for coding with thinking.
  '--temp', '0.6', '--top-p', '0.95', '--top-k', '20', '--min-p', '0', '--presence-penalty', '0', '--repeat-penalty', '1.0'
)
# Free VRAM/RAM when idle; the next request reloads the model (~5 s). The patched llama.cpp keeps the
# conversation state in the RAM prompt cache during sleep, so a resumed session does not re-read its context.
$sleep = if ($cfg.PSObject.Properties['sleepIdleSeconds']) { [int]$cfg.sleepIdleSeconds } else { 600 }
if ($sleep -gt 0) { $llamaArgs += @('--sleep-idle-seconds', "$sleep") }
if ($cfg.apiKey) { $llamaArgs += @('--api-key', $cfg.apiKey) }

& $cfg.exe @llamaArgs *>> $cfg.log

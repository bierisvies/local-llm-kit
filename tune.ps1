<#
.SYNOPSIS
  Finds the fastest stable GPU/RAM split for a MoE model: the lowest -ncmoe (most expert layers on the GPU)
  that loads, keeps >= 600 MiB VRAM free, and doesn't slow down. Binary search, ~2 min per step, ~10-15 min total.
  The KV cache is allocated for the full context at load time, so a short test predicts full-context memory use;
  finish with .\bench.ps1 -Full to confirm speed at full context.

.EXAMPLE
  .\tune.ps1            # search, then write the best -ncmoe to server\settings.json and restart the server
  .\tune.ps1 -DryRun    # only report
#>
param([int]$MinFreeMiB = 600,   # headroom for screenshots, browsers, Discord etc. (406 MiB proved too tight in practice)
       [int]$TestTokens = 32000, [switch]$DryRun)
$ErrorActionPreference = 'Stop'
$settingsPath = Join-Path $PSScriptRoot 'server\settings.json'
$startScript  = Join-Path $PSScriptRoot 'server\start-llama.ps1'
$original = Get-Content $settingsPath -Raw
$cfg = $original | ConvertFrom-Json

# Layer count and MoE-ness straight from the GGUF metadata (gguf-py ships with llama.cpp).
$gguf = Join-Path (Split-Path (Split-Path (Split-Path (Split-Path $cfg.exe)))) 'gguf-py'
$meta = & python -c @"
import sys; sys.path.insert(0, r'$gguf')
from gguf import GGUFReader
r = GGUFReader(r'$($cfg.model)')
f = {k: v.parts[-1].tolist() for k, v in r.fields.items() if k.endswith(('.block_count', '.expert_count'))}
print(next((v[0] for k, v in f.items() if k.endswith('.block_count')), 0), next((v[0] for k, v in f.items() if k.endswith('.expert_count')), 0))
"@
$layers, $experts = [int[]]("$meta".Trim() -split '\s+')
if ($experts -le 0) { throw 'Not a MoE model: -ncmoe tuning does not apply (dense models use llama.cpp --fit).' }
Write-Host "Model has $layers layers, $experts experts per layer."

function Stop-Server { Get-Process llama-server -ErrorAction SilentlyContinue | Stop-Process -Force; Start-Sleep 2 }
$headers = if ($cfg.apiKey) { @{ Authorization = "Bearer $($cfg.apiKey)" } } else { @{} }
$filler = (1..($TestTokens / 25) | ForEach-Object { "Line $_ of the synthetic log: service healthy, latency nominal, no action needed." }) -join "`n"

function Test-Split([int]$n) {
  Stop-Server
  $c = $original | ConvertFrom-Json; $c.ncmoe = "$n"
  $c | ConvertTo-Json | Set-Content $settingsPath -Encoding utf8
  Start-Process powershell.exe -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $startScript) -WindowStyle Hidden
  $deadline = (Get-Date).AddMinutes(4); $up = $false
  do {
    Start-Sleep 3
    if (-not (Get-Process llama-server -ErrorAction SilentlyContinue)) { break }   # crashed while loading (out of memory)
    try { Invoke-RestMethod "http://127.0.0.1:$($cfg.port)/health" -Headers $headers -TimeoutSec 2 | Out-Null; $up = $true } catch {}
  } while (-not $up -and (Get-Date) -lt $deadline)
  if (-not $up) { return [pscustomobject]@{ ncmoe = $n; ok = $false; why = 'failed to load'; gen = 0; prefill = 0; freeMiB = 0 } }

  $body = @{ model = $cfg.alias; max_tokens = 300; cache_prompt = $false; chat_template_kwargs = @{ enable_thinking = $false }
             messages = @(@{ role = 'user'; content = "$filler`n`nSummarise the log above in five sentences." }) } | ConvertTo-Json -Depth 5
  try { $r = Invoke-RestMethod "http://127.0.0.1:$($cfg.port)/v1/chat/completions" -Method Post -Headers $headers -ContentType 'application/json' -Body $body -TimeoutSec 900 }
  catch { return [pscustomobject]@{ ncmoe = $n; ok = $false; why = "request failed: $($_.Exception.Message)"; gen = 0; prefill = 0; freeMiB = 0 } }
  $free = [int](nvidia-smi --query-gpu=memory.free --format=csv,noheader,nounits | Select-Object -First 1)
  $res = [pscustomobject]@{ ncmoe = $n; ok = $true; why = ''; gen = [math]::Round($r.timings.predicted_per_second, 1)
                            prefill = [math]::Round($r.timings.prompt_per_second); freeMiB = $free }
  if ($free -lt $MinFreeMiB) { $res.ok = $false; $res.why = "only $free MiB VRAM free" }
  $res
}

$results = @{}
function Measure-Split([int]$n) {
  if (-not $results.ContainsKey($n)) {
    $r = Test-Split $n; $results[$n] = $r
    Write-Host ("  ncmoe {0,2}: {1}  gen {2} tok/s, prefill {3} tok/s, {4} MiB free {5}" -f $n, $(if ($r.ok) { 'OK  ' } else { 'FAIL' }), $r.gen, $r.prefill, $r.freeMiB, $r.why)
  }
  $results[$n]
}

try {
  # Binary search for the lowest ncmoe that passes. More layers in RAM (higher ncmoe) is always safe but slower.
  $lo = 0; $hi = $layers
  if (-not (Measure-Split $hi).ok) { throw "Even with all experts in RAM (ncmoe $hi) the model doesn't run stably: pick a smaller profile." }
  while ($lo -lt $hi) {
    $mid = [int][math]::Floor(($lo + $hi) / 2)
    if ((Measure-Split $mid).ok) { $hi = $mid } else { $lo = $mid + 1 }
  }
  $best = $hi
  # Safety: a spill can pass the memory check yet be slower than one step up; keep whichever is faster.
  if ($best + 1 -le $layers) {
    $up = Measure-Split ($best + 1)
    if ($up.ok -and $up.gen -gt $results[$best].gen * 1.03) { $best = $best + 1 }
  }
  $b = $results[$best]
  Write-Host "`nBest: -ncmoe $best  ($($b.gen) tok/s at ${TestTokens}-token context, $($b.freeMiB) MiB VRAM free)" -ForegroundColor Green
} finally {
  if ($DryRun -or -not $best) { Set-Content $settingsPath $original -Encoding utf8 -NoNewline }
  else { $c = $original | ConvertFrom-Json; $c.ncmoe = "$best"; $c | ConvertTo-Json | Set-Content $settingsPath -Encoding utf8 }
  Stop-Server
  Start-ScheduledTask -TaskName 'Local LLM server' -ErrorAction SilentlyContinue
  if (-not (Get-ScheduledTask -TaskName 'Local LLM server' -ErrorAction SilentlyContinue)) {
    Start-Process powershell.exe -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $startScript) -WindowStyle Hidden
  }
}
if (-not $DryRun) { Write-Host 'Saved to server\settings.json and restarted. Confirm with: .\bench.ps1 -Full' }

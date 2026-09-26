<#
.SYNOPSIS
  Quick acceptance benchmark for the running llama-server (~5-10 min). Replaces hours of manual iteration:
  if all checks pass, the setup is good; if not, PLAYBOOK.md says which single knob to turn.
#>
param(
  [int]$Port = 8080,
  [int]$LongTokens = 100000,
  [switch]$Full   # test at (almost) the full configured context: cold prefill can take 10-25 min
)
$ErrorActionPreference = 'Stop'
$cfg = Get-Content (Join-Path $PSScriptRoot 'server\settings.json') -Raw | ConvertFrom-Json
$base = "http://127.0.0.1:$Port"
if ($Full) { $LongTokens = [int]$cfg.context - 20000 }
$headers = if ($cfg.apiKey) { @{ Authorization = "Bearer $($cfg.apiKey)" } } else { @{} }

function Ask($messages, [int]$maxTokens) {
  $body = @{ model = $cfg.alias; max_tokens = $maxTokens; cache_prompt = $false; messages = $messages
             chat_template_kwargs = @{ enable_thinking = $false } } | ConvertTo-Json -Depth 8
  $sw = [Diagnostics.Stopwatch]::StartNew()
  $r = Invoke-RestMethod "$base/v1/chat/completions" -Method Post -Headers $headers -ContentType 'application/json' -Body $body -TimeoutSec 3600
  [pscustomobject]@{ seconds = [math]::Round($sw.Elapsed.TotalSeconds, 1); prompt = $r.timings.prompt_n
    prefill = [math]::Round($r.timings.prompt_per_second); gen = [math]::Round($r.timings.predicted_per_second, 1); text = $r.choices[0].message.content }
}
function SharedMiB {
  $serverPid = (Get-Process llama-server).Id
  $s = (Get-Counter '\GPU Process Memory(*)\Shared Usage').CounterSamples | Where-Object InstanceName -match "pid_${serverPid}_" |
       Measure-Object CookedValue -Sum
  [math]::Round($s.Sum / 1MB)
}
$results = [ordered]@{}

Write-Host "Profile $($cfg.profile), ncmoe '$($cfg.ncmoe)', context $($cfg.context)"
$r = Ask @(@{ role = 'user'; content = 'Write a complete Python LRU cache with TTL and thread safety, with pytest tests.' }) 1500
$results['short context generation (tok/s)'] = $r.gen
Write-Host "  short: $($r.gen) tok/s"

$needle = 'The secret deployment code is ORBIT-7713.'
$filler = (1..($LongTokens / 25) | ForEach-Object { "Line $_ of the synthetic log: service healthy, latency nominal, no action needed." }) -join "`n"
$long = $filler.Insert([int]($filler.Length / 2), "`n$needle`n")
$r = Ask @(@{ role = 'user'; content = "$long`n`nWhat is the secret deployment code? Answer with the code only." }) 200
$results["${LongTokens}-token prefill (tok/s)"] = $r.prefill
$results["${LongTokens}-token generation (tok/s)"] = $r.gen
$results['long-context retrieval correct'] = $r.text -match 'ORBIT-7713'
Write-Host "  long: $($r.prompt) prompt tokens, prefill $($r.prefill) tok/s, gen $($r.gen) tok/s, answer '$($r.text.Trim())'"

if ($cfg.mmproj) {
  Add-Type -AssemblyName System.Drawing
  $bmp = New-Object System.Drawing.Bitmap 800, 450; $g = [System.Drawing.Graphics]::FromImage($bmp)
  $g.Clear([System.Drawing.Color]::White); $g.FillEllipse([System.Drawing.Brushes]::Red, 300, 125, 200, 200); $g.Dispose()
  $ms = New-Object IO.MemoryStream; $bmp.Save($ms, [System.Drawing.Imaging.ImageFormat]::Png)
  $img = [Convert]::ToBase64String($ms.ToArray())
  $r = Ask @(@{ role = 'user'; content = @(@{ type = 'text'; text = 'What shape and colour is in this image? Answer in 3 words.' },
                                         @{ type = 'image_url'; image_url = @{ url = "data:image/png;base64,$img" } }) }) 20
  $results['image answer seconds'] = $r.seconds
  $results['image understood'] = $r.text -match 'red' -and $r.text -match 'circle|ball|dot|disc'
  Write-Host "  vision: $($r.seconds) s, answer '$($r.text.Trim())'"
}

$results['llama-server shared GPU memory (MiB, info)'] = SharedMiB
$results['VRAM free (MiB)'] = [int](nvidia-smi --query-gpu=memory.free --format=csv,noheader,nounits | Select-Object -First 1)

Write-Host "`nRESULTS"; $results.GetEnumerator() | ForEach-Object { '  {0,-38} {1}' -f $_.Key, $_.Value }
$fail = @()
if ($results['short context generation (tok/s)'] -lt 20) { $fail += 'short-context generation < 20 tok/s' }
if ($results["${LongTokens}-token generation (tok/s)"] -lt 15) { $fail += 'long-context generation < 15 tok/s' }
if (-not $results['long-context retrieval correct']) { $fail += 'long-context retrieval failed' }
# Shared usage includes ~0.9 GB of CUDA pinned host buffers even on a healthy server, so it is informational only.
# A real VRAM shortage shows up as almost no free VRAM together with the speed checks above failing.
if ($results['VRAM free (MiB)'] -lt 250) { $fail += 'VRAM almost full (< 250 MiB free): raise ncmoe by 1-2' }
if ($cfg.mmproj -and -not $results['image understood']) { $fail += 'vision answer wrong' }
if ($fail) { Write-Host "`nFAIL: $($fail -join '; ')" -ForegroundColor Red; exit 1 } else { Write-Host "`nPASS" -ForegroundColor Green }

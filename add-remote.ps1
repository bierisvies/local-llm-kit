<#
.SYNOPSIS
  Adds another PC's llama-server (started with setup.ps1 -Network) as an OpenCode provider.

.EXAMPLE
  .\add-remote.ps1 -Name GAMEPC -Address 192.168.1.20 -ApiKey abc123
  # In OpenCode pick the model "gamepc/<model>" (/models), or set it as default with -Default.
#>
param(
  [Parameter(Mandatory)][string]$Name,
  [Parameter(Mandatory)][string]$Address,
  [Parameter(Mandatory)][string]$ApiKey,
  [string]$Model = 'qwen36-35-q4km',   # alias printed by setup.ps1 on the server PC
  [int]$Port = 8080,
  [switch]$Default
)
$ErrorActionPreference = 'Stop'
$id = ($Name -replace '[^A-Za-z0-9_-]', '-').ToLower()

try { $served = Invoke-RestMethod "http://${Address}:$Port/v1/models" -Headers @{ Authorization = "Bearer $ApiKey" } -TimeoutSec 5 }
catch { throw "Cannot reach http://${Address}:$Port with that key: $($_.Exception.Message)" }

# Keep the key out of the config file: store it in a per-remote user environment variable.
$ctx = $served.data[0].meta.n_ctx; if (-not $ctx) { $ctx = 131072 }
$envVar = "LLM_KEY_$($id.ToUpper() -replace '-', '_')"
[Environment]::SetEnvironmentVariable($envVar, $ApiKey, 'User')

$path = Join-Path $HOME '.config\opencode\opencode.json'
$cfg = Get-Content $path -Raw | ConvertFrom-Json -AsHashtable
$cfg.provider[$id] = [ordered]@{
  npm = '@ai-sdk/openai-compatible'
  name = "llama.cpp on $Name"
  options = [ordered]@{ baseURL = "http://${Address}:$Port/v1"; apiKey = "{env:$envVar}" }
  models = @{ $Model = [ordered]@{
    name = "$Model ($Name)"; tools = $true; attachment = $true
    modalities = @{ input = @('text', 'image'); output = @('text') }
    limit = @{ context = $ctx; output = 32768 } } }
}
if ($Default) { $cfg.model = "$id/$Model" }
$cfg | ConvertTo-Json -Depth 10 | Set-Content $path -Encoding utf8
Write-Host "Added provider '$id' -> http://${Address}:$Port/v1. Restart OpenCode to see it."

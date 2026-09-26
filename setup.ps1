<#
.SYNOPSIS
  Reproduces the local Qwen3.6 + llama.cpp + OpenCode setup on a Windows PC with an NVIDIA GPU.

.EXAMPLE
  .\setup.ps1                      # this PC only, model auto-selected from the hardware
  .\setup.ps1 -Network             # also serve other PCs on the LAN (API key + firewall rule)
  .\setup.ps1 -Network -NcMoe 30   # override the automatic GPU/RAM split

Run from an elevated PowerShell 7 prompt (winget installs and the firewall rule need admin).
Safe to re-run: every step skips work that is already done.
#>
param(
  [string]$Profile = '',               # model profile from models.json; empty = strongest that fits (PLAYBOOK.md §2)
  [string]$Root = "$HOME\local-llm",   # llama.cpp + models go here
  [int]$NcMoe = -1,                    # expert layers kept in RAM; -1 = compute from VRAM (or llama.cpp auto-fit)
  [int]$Context = 0,                   # 0 = profile default
  [int]$Port = 8080,
  [switch]$Network,                    # listen on the LAN with an API key
  [string]$ApiKey,                     # optional fixed key for -Network (generated otherwise)
  [switch]$SkipOpenCode,               # server-only machine
  # Tune an EXISTING setup instead of downloading/building (ask the user first, see PLAYBOOK §1):
  [string]$ModelPath,                  # existing .gguf (first shard for split models); skips the download
  [string]$MmprojPath,                 # existing vision projector for that model (optional)
  [string]$LlamaServerExe,             # existing llama-server.exe; skips cloning/building llama.cpp
  [int]$SleepIdleSeconds = 600         # unload the model after this many idle seconds (0 = always loaded)
)
$ErrorActionPreference = 'Stop'
$Kit = $PSScriptRoot
$LlamaCommit = 'd2e54583c7452353eb35d40431281f6ee984332f'   # the build the reference setup was benchmarked on
$profiles = Get-Content (Join-Path $Kit 'models.json') -Raw | ConvertFrom-Json -AsHashtable
if ($ModelPath -and -not $Profile) {
  # Existing model: describe it as a custom profile; tune.ps1 finds the split afterwards.
  if (-not (Test-Path $ModelPath)) { throw "ModelPath not found: $ModelPath" }
  $Profile = 'custom'
  $name = [IO.Path]::GetFileNameWithoutExtension($ModelPath) -replace '-\d{5}-of-\d{5}$', ''
  $profiles['custom'] = @{ alias = $name.ToLower(); context = 131072; trainContext = 0; description = "Existing model $ModelPath" }
}
elseif (-not $Profile) {
  # Same rule as PLAYBOOK.md §2: strongest model that runs at >= 15 tok/s on this hardware.
  $vram = [double](nvidia-smi --query-gpu=memory.total --format=csv,noheader,nounits | Select-Object -First 1) / 1024
  $ram  = (Get-CimInstance Win32_ComputerSystem).TotalPhysicalMemory / 1GB
  $Profile = if ($ram -ge 120) { 'qwen38-flash-next' }
             elseif ($vram -ge 22) { 'qwen38-27b' }
             elseif ($vram -ge 15 -and $ram -ge 60) { 'qwen36-35b-q8' }
             elseif ($vram -ge 10 -and $ram -ge 30) { 'qwen36-35b' }
             else { 'qwen36-35b-small' }
  Write-Host "Auto-selected profile '$Profile' ($([math]::Round($vram)) GB VRAM, $([math]::Round($ram)) GB RAM)"
}
$P = $profiles[$Profile]
if (-not $P -or $Profile.StartsWith('_')) { throw "Unknown profile '$Profile'. Options: $(($profiles.Keys | ? { -not $_.StartsWith('_') }) -join ', ')" }
if (-not $Context) { $Context = $P.context }
if (-not $P.trainContext) { $P.trainContext = $Context }   # unknown for custom models: no YaRN stretching

function Step($msg) { Write-Host "`n==> $msg" -ForegroundColor Cyan }
function Refresh-Path { $env:PATH = [Environment]::GetEnvironmentVariable('PATH','Machine') + ';' + [Environment]::GetEnvironmentVariable('PATH','User') }
function Winget($id, $extra = @()) {
  $installed = winget list --id $id -e --accept-source-agreements 2>$null | Select-String -SimpleMatch $id
  if ($installed) { Write-Host "  $id already installed"; return }
  winget install --id $id -e --silent --accept-package-agreements --accept-source-agreements @extra
  if ($LASTEXITCODE -ne 0) { throw "winget install $id failed ($LASTEXITCODE)" }
}

Step 'Checking NVIDIA GPU'
$gpu = (nvidia-smi --query-gpu=name,memory.total --format=csv,noheader,nounits) -split "`n" | Select-Object -First 1
if (-not $gpu) { throw 'No NVIDIA GPU/driver found (nvidia-smi). Install the latest NVIDIA driver first.' }
$gpuName, $vramMiB = $gpu -split ',\s*'
$vramGiB = [double]$vramMiB / 1024
Write-Host "  $gpuName, $([math]::Round($vramGiB,1)) GiB VRAM"

Step 'Installing tools (winget)'
Winget 'Git.Git'
Winget 'Kitware.CMake'
Winget 'Python.Python.3.12'
Winget 'OpenJS.NodeJS.LTS'
Winget 'GitHub.cli'
Winget 'Nvidia.CUDA'
Winget 'Microsoft.VisualStudio.2022.BuildTools' @('--override', '--wait --quiet --add Microsoft.VisualStudio.Workload.VCTools --includeRecommended')
Refresh-Path

if ($LlamaServerExe) {
  if (-not (Test-Path $LlamaServerExe)) { throw "LlamaServerExe not found: $LlamaServerExe" }
  $server = (Resolve-Path $LlamaServerExe).Path
  Step "Using existing llama-server: $server"
} else {
Step "Building llama.cpp ($($LlamaCommit.Substring(0,7))) with CUDA"
New-Item -ItemType Directory -Force $Root | Out-Null
$llama = Join-Path $Root 'llama.cpp'
if (-not (Test-Path $llama)) { git clone https://github.com/ggml-org/llama.cpp $llama }
git -C $llama fetch --quiet origin
git -C $llama checkout --quiet $LlamaCommit
# Local patch: keep the conversation state in the RAM prompt cache while the server sleeps (see patches\).
$patch = Join-Path $Kit 'patches\keep-prompt-cache-on-sleep.patch'
git -C $llama apply --check $patch 2>$null
if ($LASTEXITCODE -eq 0) { git -C $llama apply $patch; Remove-Item (Join-Path $llama 'build\bin\Release\llama-server.exe') -ErrorAction SilentlyContinue }
$server = Join-Path $llama 'build\bin\Release\llama-server.exe'
if (-not (Test-Path $server)) {
  cmake -S $llama -B (Join-Path $llama 'build') -DGGML_CUDA=ON -DLLAMA_CURL=OFF
  cmake --build (Join-Path $llama 'build') --config Release --target llama-server -j
  if (-not (Test-Path $server)) { throw 'llama.cpp build failed' }
}
}

if ($ModelPath) {
  Step "Using existing model: $ModelPath"
  $model = (Resolve-Path $ModelPath).Path
  $mmproj = if ($MmprojPath) { (Resolve-Path $MmprojPath).Path } else { '' }
} else {
Step "Downloading model files for profile '$Profile' ($($P.repo))"
$models = Join-Path $Root "models\$Profile"
New-Item -ItemType Directory -Force $models | Out-Null
$tree = Invoke-RestMethod "https://huggingface.co/api/models/$($P.repo)/tree/main?recursive=1"
$wanted = @($tree | Where-Object { $_.type -eq 'file' -and $_.path -match $P.files } | Sort-Object path)
if ($P.mmproj) { $wanted += @($tree | Where-Object { $_.path -eq $P.mmproj }) }
if (-not $wanted) { throw "No files on Hugging Face match '$($P.files)' in $($P.repo)" }
$gb = [math]::Round(($wanted | Measure-Object size -Sum).Sum / 1GB, 1)
Write-Host "  $($wanted.Count) file(s), $gb GB"
foreach ($f in $wanted) {
  $dest = Join-Path $models (Split-Path $f.path -Leaf)
  if ((Test-Path $dest) -and (Get-Item $dest).Length -eq $f.size) { continue }
  curl.exe -L --fail --retry 5 -C - -o $dest "https://huggingface.co/$($P.repo)/resolve/main/$($f.path)"   # -C - resumes
  if ($LASTEXITCODE -ne 0) { throw "download failed: $($f.path)" }
}
# Sharded models load from their first shard.
$model  = Join-Path $models (Split-Path ($wanted | Where-Object { $_.path -match $P.files } | Select-Object -First 1).path -Leaf)
$mmproj = if ($P.mmproj) { Join-Path $models $P.mmproj } else { '' }
}

Step 'Choosing GPU/RAM split'
if ($NcMoe -lt 0 -and $P.split) {
  # Measured budget (GiB): non-expert weights, KV cache (scales with context), compute buffers 1.3,
  # vision encoder 0.9, and 2.5 headroom for Windows/desktop apps (less made the model spill into shared memory).
  $s = $P.split
  $reserve = $s.nonExpert + $s.kvPer384k * ($Context / 393216) + 1.3 + ($(if ($mmproj) { 0.9 } else { 0 })) + 2.5
  $layersOnGpu = [math]::Floor(($vramGiB - $reserve) / $s.expertLayer)
  $NcMoe = [math]::Max(0, [math]::Min($s.layers, $s.layers - $layersOnGpu))
}
$threads = (Get-CimInstance Win32_Processor | Measure-Object NumberOfCores -Sum).Sum
if ($NcMoe -ge 0) { Write-Host "  -ncmoe $NcMoe, $threads threads" } else { Write-Host "  automatic fit (--fit on, 2.5 GiB headroom), $threads threads" }

if ($Network) {
  if (-not $ApiKey) { $ApiKey = -join ((48..57) + (97..122) | Get-Random -Count 40 | ForEach-Object { [char]$_ }) }
  $hostAddr = '0.0.0.0'
  Step "Opening firewall port $Port for the local subnet only"
  if (-not (Get-NetFirewallRule -DisplayName 'Local LLM (llama-server)' -ErrorAction SilentlyContinue)) {
    New-NetFirewallRule -DisplayName 'Local LLM (llama-server)' -Direction Inbound -Protocol TCP -LocalPort $Port `
      -RemoteAddress LocalSubnet -Profile Private,Domain -Action Allow | Out-Null
  }
} else { $hostAddr = '127.0.0.1' }

$settings = [ordered]@{
  profile = $Profile; alias = $P.alias
  exe = $server; model = $model; mmproj = $mmproj; host = $hostAddr; port = "$Port"
  ncmoe = $(if ($NcMoe -ge 0) { "$NcMoe" } else { '' }); context = "$Context"; trainContext = "$($P.trainContext)"
  threads = "$threads"; apiKey = $ApiKey; sleepIdleSeconds = "$SleepIdleSeconds"
  log = Join-Path $Root 'llama-server.log'
}
$settings | ConvertTo-Json | Set-Content (Join-Path $Kit 'server\settings.json') -Encoding utf8
if ($ApiKey) { [Environment]::SetEnvironmentVariable('LOCAL_LLM_API_KEY', $ApiKey, 'User'); $env:LOCAL_LLM_API_KEY = $ApiKey }

Step 'Registering autostart at logon'
$startScript = Join-Path $Kit 'server\start-llama.ps1'
$action  = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$startScript`""
$trigger = New-ScheduledTaskTrigger -AtLogOn -User "$env:USERDOMAIN\$env:USERNAME"; $trigger.Delay = 'PT30S'
$taskSettings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit ([TimeSpan]::Zero) -MultipleInstances IgnoreNew
Register-ScheduledTask -TaskName 'Local LLM server' -Action $action -Trigger $trigger -Settings $taskSettings -Force | Out-Null

if (-not $SkipOpenCode) {
  Step 'Applying the OpenCode agent setup (merged into any existing config)'
  $applyArgs = @{ Alias = $P.alias; Context = $Context; BaseUrl = "http://127.0.0.1:$Port/v1" }
  if (-not $mmproj) { $applyArgs.NoVision = $true }
  & (Join-Path $Kit 'opencode-apply.ps1') @applyArgs
}

Step 'Starting the server'
Get-Process llama-server -ErrorAction SilentlyContinue | Stop-Process -Force
Start-ScheduledTask -TaskName 'Local LLM server'
$deadline = (Get-Date).AddMinutes(3); $ok = $false
do {
  Start-Sleep 3
  try { Invoke-RestMethod "http://127.0.0.1:$Port/health" -TimeoutSec 2 | Out-Null; $ok = $true } catch {}
} while (-not $ok -and (Get-Date) -lt $deadline)
if (-not $ok) { throw "Server did not come up; see $($settings.log)" }

$ip = (Get-NetIPAddress -AddressFamily IPv4 | Where-Object { $_.PrefixOrigin -in 'Dhcp','Manual' -and $_.IPAddress -notlike '169.*' } | Select-Object -First 1).IPAddress
Write-Host "`nDone. Server: http://127.0.0.1:$Port/v1 (model $($P.alias))" -ForegroundColor Green
if ($Network) {
  Write-Host "LAN address: http://${ip}:$Port/v1   API key: $ApiKey"
  Write-Host "On other PCs:  .\add-remote.ps1 -Name $env:COMPUTERNAME -Address $ip -ApiKey $ApiKey -Model $($P.alias)"
}
Write-Host "Next: .\tune.ps1 (MoE models: fastest stable split), then .\bench.ps1 -Full and .\bench-agent.ps1 (see PLAYBOOK.md)."

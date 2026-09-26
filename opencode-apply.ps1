<#
.SYNOPSIS
  Applies the tuned OpenCode agent setup to this PC, MERGING into an existing OpenCode config instead of replacing it.
  Adds: system prompt (AGENTS.md), plugins (post-edit-check, cleanup-apps), drive-app.py, frontend-design skill,
  Playwright + Context7 MCP, coding sampling for the build/plan agents, skill denies, compaction, and the local model.
  Keeps: your other providers/models, MCP servers, permissions, agents, UI settings (cli.json) and your own AGENTS.md
  (moved to AGENTS.user.md and still loaded via "instructions"). A full backup is made first.

.EXAMPLE
  .\opencode-apply.ps1 -Alias qwen36-35-q4km -Context 393216                  # model served on this PC
  .\opencode-apply.ps1 -Alias qwen36-35-q4km -Context 393216 -NoVision
  # For a model on another PC use add-remote.ps1 afterwards (and -SkipModel here).
#>
param(
  [string]$Alias,                    # model alias served by llama-server (settings.json "alias")
  [int]$Context = 393216,
  [switch]$NoVision,                 # model has no mmproj
  [string]$BaseUrl = 'http://127.0.0.1:8080/v1',
  [switch]$SkipModel,                # only apply prompt/plugins/tools/MCP, don't add a model
  [switch]$KeepDefaultModel,         # don't switch OpenCode's default model to this one
  [string]$ConfigDir = (Join-Path $HOME '.config\opencode')
)
$ErrorActionPreference = 'Stop'
$Kit = $PSScriptRoot
$src = Join-Path $Kit 'opencode'
$oc  = $ConfigDir

# OpenCode v2 is required (the plugins use the v2 plugin API).
$ver = try { (opencode --version 2>$null | Select-Object -First 1) -replace '[^\d\.]', '' } catch { '' }
if (-not $ver -or [version]($ver.Split('.')[0..2] -join '.') -lt [version]'2.0.16') {
  Write-Host "Installing OpenCode 2.0.16 (found: $(if ($ver) { $ver } else { 'none' }))"
  npm install -g '@opencode/cli@2.0.16'
  if ($LASTEXITCODE -ne 0) { throw 'npm install @opencode/cli failed' }
}
python -m pip install --quiet --upgrade pillow   # drive-app.py screenshots

New-Item -ItemType Directory -Force $oc | Out-Null
if (Get-ChildItem $oc -Force | Where-Object Name -notlike '*.backup-*') {
  $backup = "$oc.backup-$(Get-Date -Format yyyyMMdd-HHmmss)"
  Copy-Item $oc $backup -Recurse
  Write-Host "Backup of existing OpenCode config: $backup"
}
if (Test-Path (Join-Path $oc 'opencode.jsonc')) {
  Write-Warning "opencode.jsonc found: OpenCode may prefer it over opencode.json. Merge it manually or rename it; this script edits opencode.json."
}

# 1. Files: plugins, scripts, skills (ours are overwritten, the user's other files stay).
foreach ($dir in 'plugins', 'scripts', 'skills') {
  New-Item -ItemType Directory -Force (Join-Path $oc $dir) | Out-Null
  Copy-Item (Join-Path $src "$dir\*") (Join-Path $oc $dir) -Recurse -Force
}
if (-not (Test-Path (Join-Path $oc 'cli.json'))) { Copy-Item (Join-Path $src 'cli.json') $oc }   # UI prefs: only if absent

# 2. System prompt: ours becomes AGENTS.md; a different existing one is kept as AGENTS.user.md and still loaded.
$agents = Join-Path $oc 'AGENTS.md'
$keepUserPrompt = $false
if ((Test-Path $agents) -and ((Get-FileHash $agents).Hash -ne (Get-FileHash (Join-Path $src 'AGENTS.md')).Hash)) {
  $userPrompt = Join-Path $oc 'AGENTS.user.md'
  if (-not (Test-Path $userPrompt)) { Move-Item $agents $userPrompt } else { Remove-Item $agents }
  $keepUserPrompt = $true
  Write-Host 'Existing AGENTS.md kept as AGENTS.user.md (loaded after the kit prompt).'
}
Copy-Item (Join-Path $src 'AGENTS.md') $agents -Force

# 3. Config: merge.
$cfgPath = Join-Path $oc 'opencode.json'
$cfg  = if (Test-Path $cfgPath) { Get-Content $cfgPath -Raw | ConvertFrom-Json -AsHashtable } else { [ordered]@{} }
$ours = Get-Content (Join-Path $src 'opencode.json') -Raw | ConvertFrom-Json -AsHashtable
function Ensure($table, $key) { if (-not $table.Contains($key) -or $null -eq $table[$key]) { $table[$key] = [ordered]@{} }; $table[$key] }

if (-not $cfg.Contains('$schema')) { $cfg['$schema'] = $ours['$schema'] }
foreach ($name in $ours.mcp.Keys) { (Ensure $cfg 'mcp')[$name] = $ours.mcp[$name] }                       # add/refresh our MCP servers
$skill = Ensure (Ensure $cfg 'permission') 'skill'
foreach ($k in $ours.permission.skill.Keys) { $skill[$k] = $ours.permission.skill[$k] }
foreach ($a in 'build', 'plan') {                                                                         # coding sampling
  $agent = Ensure (Ensure $cfg 'agent') $a
  foreach ($k in $ours.agent[$a].Keys) { $agent[$k] = $ours.agent[$a][$k] }
}
if (-not $cfg.Contains('compaction')) { $cfg['compaction'] = $ours.compaction }
if ($keepUserPrompt) {
  $userPath = Join-Path $oc 'AGENTS.user.md'
  $instr = @($cfg['instructions'] | Where-Object { $_ })
  if ($instr -notcontains $userPath) { $cfg['instructions'] = @($instr + $userPath) }
}

if (-not $SkipModel) {
  if (-not $Alias) { throw 'Pass -Alias (the model alias from server\settings.json) or -SkipModel.' }
  $local = Ensure (Ensure $cfg 'provider') 'local'
  foreach ($k in $ours.provider.local.Keys) { if ($k -ne 'models' -and -not $local.Contains($k)) { $local[$k] = $ours.provider.local[$k] } }
  $local.options.baseURL = $BaseUrl
  $models = Ensure $local 'models'
  $m = $ours.provider.local.models['qwen36-35-q4km'] | ConvertTo-Json -Depth 10 | ConvertFrom-Json -AsHashtable
  $m.name = "$Alias (this PC)"; $m.limit.context = $Context
  if ($NoVision) { $m.Remove('attachment'); $m.modalities.input = @('text') }
  $models[$Alias] = $m
  if (-not $KeepDefaultModel -or -not $cfg.Contains('model')) {
    if ($cfg.Contains('model') -and $cfg.model -ne "local/$Alias") { Write-Host "Default model changed: $($cfg.model) -> local/$Alias (use -KeepDefaultModel to keep it)" }
    $cfg.model = "local/$Alias"
  }
}

$cfg | ConvertTo-Json -Depth 20 | Set-Content $cfgPath -Encoding utf8
Write-Host "OpenCode agent setup applied to $oc. Restart OpenCode (and its background service) to load it."

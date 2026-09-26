# Local LLM kit (Qwen3.6 + llama.cpp + OpenCode)

Reproduces the tuned local coding setup from the reference PC on another Windows + NVIDIA machine,
and lets PCs on the same network use each other's models.

## Quick start (on the new PC)
1. Copy this folder to the PC (keep it in place afterwards: the autostart task runs `server\start-llama.ps1` from here).
2. Open **PowerShell 7 as administrator** in this folder.
3. Pick a profile (see `PLAYBOOK.md` §2; pick the strongest model your hardware allows: Qwen3.8-Flash-Next with 128 GB RAM, Qwen3.8-27B with a 24 GB GPU, otherwise Qwen3.6):
   ```
   .\setup.ps1 -Network        # model auto-selected from the hardware; or add -Profile <name>
   ```
4. Tune and check: `.\tune.ps1` (fastest stable GPU/RAM split for MoE models, ~10–15 min), then `.\bench.ps1 -Full` and `.\bench-agent.ps1` → both must say PASS.
5. On other PCs: `.\add-remote.ps1 -Name <pc> -Address <ip> -ApiKey <key> -Model <alias>` (values printed by setup).

Or open Claude Code in this folder and say "set this PC up": `CLAUDE.md` points it to the playbook.

## Contents
| File | Purpose |
|---|---|
| `setup.ps1` | Installs tools, builds llama.cpp (pinned commit), downloads the model, computes GPU/RAM split, autostart, OpenCode config |
| `models.json` | Model profiles (small / default / q8 / 27B / Flash-Next) |
| `server\start-llama.ps1` | Server launch flags (reads `server\settings.json`) |
| `tune.ps1` | Binary search over `-ncmoe` (expert layers in RAM) for the fastest stable split; saves the winner |
| `bench.ps1` | 5–10 min acceptance test: speed, 100k needle, vision, VRAM spill (`-Full` = full context) |
| `bench-agent.ps1` | Checks the OpenCode agent: tools work, system-prompt rules are followed |
| `add-remote.ps1` | Adds another PC's server to OpenCode |
| `opencode\` | System prompt (AGENTS.md), config, cleanup plugin, input driver, design skill |
| `PLAYBOOK.md` | Everything learned: goal, what to pick, what to tune, what not to try, and why |
| `AGENT.md` | Every OpenCode optimisation (settings, system-prompt rules, tools) with the failure that motivated it |

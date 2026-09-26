# PLAYBOOK — local coding LLM on a Windows PC (for Claude / an agent doing the setup)

This kit is the result of ~30 hours of benchmarking on a reference PC. **Do not repeat that search.**
Read the hardware, pick a profile from the table, run `setup.ps1`, run `bench.ps1`, and only tune the
single knob the failing check points to. Target: working and verified in < 1 hour (mostly download time).

Reference PC: RTX 4070 12 GB · Ryzen 7 7700X (8 cores) · 64 GB DDR5 dual-channel · Windows 11 · driver 610.
Reference result (profile `qwen36-35b`, `-ncmoe 34`, vision on GPU):
- ~42 tok/s generation at short context, ~37 tok/s at 100k, ~21 tok/s at 376k
- ~800 tok/s prefill at 100k, ~630 tok/s at 376k (cold 376k prompt ≈ 10–12 min)
- screenshot understood in ~7 s; 4/4 needles retrieved at 376k; OpenCode agent tests pass

## 0. The goal (what "best setup" means here)

Optimise in this order: **(1) the strongest model** the hardware can run → **(2) the largest usable context** →
**(3) high thinking always on** → **(4) speed floor: ≥ 15 tok/s at full context, ≥ 20 tok/s short** →
**(5) an agent that builds, tests, looks at and honestly reports its own work** (see `AGENT.md`).
Never trade (1)–(3) for extra speed above the floor.

## 1a. FIRST ask the user: is there an existing model/setup to tune?

Before installing anything, ask:
1. "Is there already a local model on this PC (a .gguf file, llama.cpp, Ollama, LM Studio) that should be tuned instead of replaced?"
2. If yes: its path (and the mmproj/vision file if any) and whether an existing `llama-server.exe` should be kept.
3. "Should other PCs on your network be able to use this model?" Only if yes: `-Network` (API key + firewall rule).
   `add-remote.ps1` is only for PCs that should *use* another PC's model; skip it otherwise.
4. "Is OpenCode already installed/configured here?" The kit's agent setup is always applied, but merged
   (`opencode-apply.ps1`): existing providers, MCP servers, permissions and the user's own AGENTS.md are kept
   (their prompt becomes `AGENTS.user.md`, still loaded). A full backup is made first.

Then:
- **Existing model + llama.cpp** → `.\setup.ps1 -ModelPath <gguf> [-MmprojPath <mmproj>] -LlamaServerExe <exe>` (no download, no build), then `tune.ps1`, then bench.
- **Existing model, no llama.cpp** → `.\setup.ps1 -ModelPath <gguf> [-MmprojPath <mmproj>]` (builds llama.cpp only).
- **Ollama / LM Studio models**: their GGUF blobs can be used directly with `-ModelPath` (Ollama: `%USERPROFILE%\.ollama\models\blobs\sha256-…`, the largest blob of the model; LM Studio: `%USERPROFILE%\.lmstudio\models\…`).
- Still compare against §2: if the existing model is clearly weaker than what the hardware can run, tell the user and let them choose.
- **No existing model** → continue with §1 and §2.

## 1. Read the hardware (2 minutes)

```powershell
nvidia-smi --query-gpu=name,memory.total,driver_version --format=csv
(Get-CimInstance Win32_ComputerSystem).TotalPhysicalMemory / 1GB
Get-CimInstance Win32_PhysicalMemory | Select Capacity,Speed    # module count ~ channels on desktops
(Get-CimInstance Win32_Processor).Name
```

## 2. Pick the profile: the strongest model the hardware can run at ≥ 15 tok/s

Quality ranking (Artificial Analysis, agentic coding): **Qwen3.8-Flash-Next** (Terminal-Bench 4: 25%, AutomationBench 56%)
> **Qwen3.8-27B** (TB4 6%) > **Qwen3.6-35B-A3B** (TB4 0%, AutomationBench 5%). Qwen3.6 was chosen on the reference PC
only because the better models don't run fast enough on 12 GB VRAM / 64 GB RAM. Always try the highest row that fits;
step down one row only if `bench.ps1` fails on speed.

| Hardware (first matching row wins) | Profile | Why |
|---|---|---|
| ≥ 128 GB RAM or unified memory (DGX Spark, 128 GB+ desktop) | **`qwen38-flash-next`** | Best model. ~90 GB Q3_K_XL; MoE 6B active → usable speed from RAM. Needs newer llama.cpp (§6). |
| ≥ 24 GB VRAM (3090/4090/5090) | **`qwen38-27b`** | Dense 27B Q4 (16.5 GB) fits fully in VRAM → fast. Must be 100% in VRAM: if bench shows spill or < 15 tok/s, drop to `qwen36-35b-q8`. |
| 16–23 GB VRAM + ≥ 64 GB RAM | `qwen36-35b-q8` | Qwen3.8-27B won't fit in VRAM (dense in RAM = ~4 tok/s); best Qwen3.6 quant instead. |
| 10–16 GB VRAM + ≥ 32 GB RAM | `qwen36-35b` | The measured reference setup. |
| 8 GB VRAM or < 32 GB RAM | `qwen36-35b-small` | IQ3 quant, 128k context. |
| no NVIDIA GPU | — | Out of scope (CUDA build). |

Only `qwen36-35b` is measured; the others use llama.cpp's automatic `--fit`. `bench.ps1` decides.

## 3. Install

```powershell
.\setup.ps1                           # local only; profile auto-selected with the §2 rule
.\setup.ps1 -Network                  # only if the user wants other PCs to use it (API key + firewall rule, LocalSubnet only)
.\setup.ps1 -Profile qwen38-27b       # force a profile (e.g. step down after a failed bench)
```
Elevated PowerShell 7. It installs Git, CMake, Python, Node, gh, CUDA, VS Build Tools (C++), builds llama.cpp at
the pinned commit, downloads the model, computes the GPU/RAM split, registers autostart, installs OpenCode 2.0.16 with
the agent config, and starts the server. Re-runnable.

## 4. Verify

```powershell
.\bench.ps1          # ~5–10 min: ≥20 tok/s short, ≥15 tok/s at 100k, needle found, ≥ 250 MiB VRAM free, vision OK
.\bench.ps1 -Full    # same at (almost) the full context: the real speed-floor check (10–25 min cold prefill)
.\bench-agent.ps1    # OpenCode: tools (Context7, Playwright) work and the type-check rule is followed
```

**Maximising context** (goal 2): start at the profile's context. If `-Full` passes with margin (> 18 tok/s), try the next
step up (393216 → 458752 → 524288; the YaRN scale follows automatically) by editing `context` in `server\settings.json`,
restart the task, run `bench.ps1 -Full` again; if it fails on speed, step back down. Keep OpenCode's `limit.context` equal.
Reference PC: 512k passed at 17.4 tok/s but cold prefill took 22 min, so 384k (21 tok/s, ~11 min) was chosen.

## 5. If bench fails — turn ONE knob

| Symptom | Cause | Fix |
|---|---|---|
| "VRAM almost full", or speed collapses to 1–10 tok/s | VRAM too tight (other apps, long context) | Close GPU-heavy apps and re-run `tune.ps1`, or raise `ncmoe` by 1–2 in `server\settings.json`, restart the task. Also: Discord hardware acceleration + Clips use ~1 GB VRAM — turn them off. |
| Lots of free VRAM (> 1.5 GB idle) | Split too conservative | Run `tune.ps1` (or lower `ncmoe` by 1–2 by hand). Each MoE layer on GPU ≈ +1–2% generation speed. |
| Short-context gen < 20 tok/s with no spill | RAM bandwidth-bound (few memory channels) | Expected on dual-channel DDR4. Use `qwen36-35b-small` or accept it. |
| Prefill slow | micro-batch | `-ub 1024` is already set (512 → 1024 was +70% prefill). 2048 only if VRAM allows. |
| Server won't start / crashes on load | Driver/CUDA mismatch or arch unsupported | Check `$HOME\local-llm\llama-server.log`. For new model archs update llama.cpp (§6). |
| Everything suddenly 100× slower mid-session | A GUI app the agent started is still running (GPU contention) | The `cleanup-apps` OpenCode plugin prevents this; check `Get-Process` for leftovers. |

## 6. What NOT to try (already measured, all worse or pointless)

- **Speculative decoding** (`--spec-type ngram-mod`): 3–7% *slower* — experts in RAM make verification expensive.
- **Dense models that don't fit fully in VRAM** (e.g. Qwen3.8-27B on 12 GB): ~3.8 tok/s. On a 24 GB card it does fit and is the better choice.
- **Vision encoder on CPU** (`--no-mmproj-offload`): 84 s per screenshot vs 7 s on GPU. Moving 3–4 expert layers to RAM to make room costs only ~1 tok/s.
- **Q8 KV cache at 384k**: doesn't fit 12 GB. Q4 KV passed the 376k needle + bug-fix test.
- **presence-penalty 1.5** (Qwen's *general* preset): hurts code. Use the coding preset (temp 0.6, top-p 0.95, top-k 20, presence 0).
- **Mixing a Pascal card (GTX 10xx)**: needs the whole system on driver 580 + a CUDA 12 rebuild. Not worth it.
- **Intel Arc + NVIDIA mix**: Vulkan only, SYCL has a recurrent-state bug with Qwen3.5/3.6/3.8 hybrids.
- **LSP in OpenCode v2**: does nothing (v2 doesn't run LSP diagnostics). The `post-edit-check` plugin replaces it.
- **MemPalace-style memory plugins**: injecting varying memory at the top of the prompt breaks llama.cpp's prompt cache (every turn re-prefills).
- **Lower OpenCode context limit to force early compaction**: user declined; keep 393k.

OpenCode-only PC (uses another PC's model): `.\opencode-apply.ps1 -SkipModel`, then `add-remote.ps1`.

To update llama.cpp (needed for `qwen38-flash-next`): `git -C $HOME\local-llm\llama.cpp checkout master; git pull`,
delete `build\`, re-run `setup.ps1` (edit `$LlamaCommit` first), then `bench.ps1` again.

## 7. Why the key settings are what they are

- **MoE split `-ncmoe N`**: attention + shared weights of all layers on GPU, expert weights of the first N layers in RAM.
  Generation is bound by reading those experts from RAM; every layer moved to GPU helps a little.
- **Budget formula** (setup.ps1): non-expert 2.4 GiB + KV 2.1 GiB per 384k (Q4) + compute 1.3 + vision 0.9 + **2.5 headroom**;
  each expert layer 0.456 GiB. The 2.5 GiB headroom is essential: with ~0.2 GiB free, Windows paged the model into
  shared memory and generation fell from ~20 to ~1 tok/s.
- **KV cache is tiny** because only 10 of 40 layers use full attention (the rest are linear/DeltaNet with fixed state) and there are 2 KV heads.
- **YaRN 1.5×** stretches the trained 262k to 393k; the 376k needle test passed.
- **Thinking high, budget 32k**: quality over speed was the explicit choice.
- **Idle sleep** (`sleepIdleSeconds`, default 600): after 10 idle minutes llama-server unloads the model
  (VRAM 11.1 → 1.4 GB, RAM 7.8 → 1.2 GB) so games etc. get the GPU back; the next request reloads it (~5 s).
  Stock llama.cpp wipes the prompt cache on wake, so a resumed 52k session re-read everything (61 s).
  `patches/keep-prompt-cache-on-sleep.patch` (applied by setup) keeps it in RAM: the same turn after sleep took 6 s.
  Qwen3.6 is hybrid (recurrent layers), so a saved slot file (`--slot-save-path`) is NOT enough: it lacks the
  checkpoints needed to reuse a prefix. The in-RAM prompt cache has them. Set 0 to keep the model always loaded.
  Upstream fix: https://github.com/ggml-org/llama.cpp/pull/29408 (same approach, verified to give the same 6 s resume).
  Once it is merged, update llama.cpp past it and drop the patch.
- **Pause for games**: `server\install-pause-controls.ps1` adds desktop shortcuts (pause/resume) and a logon task
  `game-watch.ps1` that pauses the server while a game runs (list: `gameProcesses` in settings.json) and resumes it
  after. Pause stops llama-server immediately (all VRAM free, a running task is aborted) and sets
  `%LOCALAPPDATA%\local-llm\paused.flag`, which the autostart respects. A manual pause is never auto-resumed.
- **`-np 1`**: one request at a time, full context. Several LAN users will queue. `-np 2` halves the context per slot.

## 8. OpenCode agent config (merged into `~/.config/opencode` by `opencode-apply.ps1`, called from setup) — full detail in `AGENT.md`

- `AGENTS.md`: system prompt. Key rules, each added after a real failure: static checks after every edit;
  build in small steps (no 300+ line files, no whole-file rewrites); look up the installed library API before coding
  (Context7 → installed package docs/XML → GitHub tree via gh; never guess URLs); install missing tools instead of
  working around them; test native apps like a user with `drive-app.py` and compare screenshots; rebuild before
  every test; reproduce → fix → re-run the same scenario for bug reports; feature-by-feature ✅/⚠️/❌ final report;
  never leave GUI apps running; PowerShell syntax, not bash.
- `plugins/post-edit-check.js`: runs tsc/ruff/dotnet build/cargo check/go vet after every edit and shows the errors to the model (LSP replacement; prompt rules alone were not followed reliably).
- `plugins/cleanup-apps.js`: after every turn, kills processes whose exe lives inside the session's project folder.
- `scripts/drive-app.py`: real keyboard/mouse (SendInput) + screenshots for native apps; prints the app's exception on crash. Needs Pillow.
- `skills/frontend-design`: Anthropic's design skill (Apache-2.0).
- MCP: Playwright (headless browser) and Context7 (library docs). Caveman skills denied (useless locally).
- Sampling in `agent.build/plan` matches the server. `compaction.auto` on.

## 9. Network use

- Server PC: `setup.ps1 -Network` → prints `http://<ip>:8080/v1` and an API key. Firewall rule allows only the local subnet on Private/Domain networks.
- Client PC: `.\add-remote.ps1 -Name GAMEPC -Address 192.168.1.20 -ApiKey <key> -Model <alias>` → adds a provider to OpenCode (key stored in a user env var, not in the file).
- Any OpenAI-compatible client works: base URL `http://<ip>:8080/v1`, header `Authorization: Bearer <key>`, model = alias.

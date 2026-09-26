# OpenCode agent optimizations (what `setup.ps1` installs into `~/.config/opencode`)

Goal of the whole setup, in priority order:
1. **Best model** the hardware can run (quality first; see PLAYBOOK §2).
2. **Highest usable context** (reference: 384k; 512k also passed but prefill took 22 min cold).
3. **High thinking** always on (effort high, 32k budget). Quality over speed.
4. **Speed floor**: ≥ 15 tok/s generation at full context, ≥ 20 tok/s at short context.
5. The agent must **finish and verify** its work on its own (build, test, run, look at the result) and report honestly.

Every rule below was added after a concrete failure seen in real sessions on the reference PC.

## Model / server settings the agent depends on
| Setting | Value | Why |
|---|---|---|
| Thinking | `--reasoning on --reasoning-effort high --reasoning-budget 32768`, output limit 32k | Qwen recommends 32k output; 16k cut reasoning short on large tasks |
| Sampling | temp 0.6, top-p 0.95, top-k 20, min-p 0, presence 0, repeat 1.0 (server **and** OpenCode `agent.build/plan`) | Qwen's coding-with-thinking preset. The old general preset (presence 1.5) penalised repeated identifiers → bad code |
| Context | 393216 in server and OpenCode `limit.context` | Keep both equal or OpenCode compacts too early/late |
| Prompt cache | `--cache-prompt`, `-np 1` | ~98% of the prefix is reused between agent turns, so a long session only pays prefill once |
| Vision | `--mmproj` on GPU, OpenCode `attachment: true` + image modality | Agent can read screenshots (7 s each). CPU vision took 84 s |
| Compaction | `compaction.auto: true` | Default; the user chose to keep the full 393k window |

## System prompt (`AGENTS.md`) — rules and the failure behind each
Order matters: a rule at the bottom of a long prompt was ignored even though the model could quote it. Critical rules are at the top.

| Rule | Failure it fixed |
|---|---|
| **Run the type checker/linter after every code edit**, fix all new errors | A rename broke another file; the edit tool reported success. The rule alone was followed only sometimes, so the `post-edit-check` plugin now enforces it |
| **Build in small steps** (build after each file / ~150 lines, no files > 300 lines, fix errors in place, no whole-file rewrites) | It wrote a 40 KB file, then hit 226 compile errors and rewrote it 3× (~18 min wasted) |
| **Look up the installed library's API first** (Context7 → package docs/.d.ts/NuGet XML → GitHub tree via `gh`; never guess URLs) | It wrote Raylib-cs code from memory: hundreds of wrong-API errors and three 404s on guessed GitHub URLs |
| **Shell is PowerShell 7, not bash** | `ls -la`, `grep`, `head`, `mkdir a b c` failed repeatedly |
| **Install missing tools** (winget/npm/pip/NuGet, exact IDs, report UAC waits) | Chose a worse stack to avoid installing things |
| **Pick the stack for the best result**, not the easiest to test (e.g. native for low-latency apps) | Built an aim trainer in the browser; raw mouse input needs native |
| **Autonomous build mode**: no questions, PLAN.md with milestones, commit per verified milestone, don't stop early | Stopped half-done, put everything in one commit |
| **Test native apps like a user with `drive-app.py`** (real keys/mouse, screenshots, compare before/after) | Declared "all screens verified" without ever reaching the game screen; SendKeys didn't reach Raylib |
| **Launch apps only through the driver, always `--close`** | Leftover app instances locked the build output (MSB3021) and stole GPU → model slowed to 0.05 tok/s |
| **Rebuild before every driven test** | Tested a stale publish folder for several rounds |
| **Bug reports: reproduce → fix → re-run the same scenario**; "the code looks correct" is not verification | Claimed flick targets were fixed without ever seeing one |
| **Debug aids that don't show up are evidence** | Added a red debug cube, it never appeared, deleted it — that was the camera bug |
| **On a crash, read the app's exception first** | Guessed "access violation"; the log said `Collection was modified` in `Update()` |
| **Tests: decide whether code or test is wrong**; only change expectations with a shown calculation | "Fixed" failing tests by editing the expected values |
| **Never drop a feature silently; final report per feature ✅/⚠️/❌ with proof** | Stubbed out sound and marked every milestone ✅ |
| **Plan mode: present the plan, tell the user to switch to Build** | 5 blocked write attempts in Plan mode |
| **Git identity only per repo, and say so** | Silently set `opencode@local` |
| Communication: direct, complete, user's language; no "caveman" compression | Tokens are free locally; clarity matters more |
| Karpathy-style coding guidelines, accuracy and safety sections | Baseline quality rules |

## Tools
| Tool | Why |
|---|---|
| **Playwright MCP** (headless, isolated) | Real browser for web apps: navigate, click, screenshot |
| **Context7 MCP** | Up-to-date library docs; compensates for the model's outdated API memory (it hallucinates: AA-Omniscience −22) |
| **`gh` CLI** (logged in) | Issues/PRs/CI and reading exact source files from GitHub without guessing URLs |
| **`scripts/drive-app.py`** | SendInput keyboard/mouse + window screenshots + crash output for native apps. Replaces SendKeys (didn't reach Raylib/GLFW) |
| **`plugins/post-edit-check.js`** | After every `edit`/`write`, runs the project checker (tsc / ruff or py_compile / dotnet build / cargo check / go vet) and appends errors to the tool result. Enforces the type-check rule: with the prompt rule alone the model skipped it in 1 of 2 test runs; with the plugin it fixed the broken file itself in 2/2 |
| **`plugins/cleanup-apps.js`** | After every turn, kills processes whose exe lives in the project folder (OpenCode v2 plugin API: `session.execution.*` events) |
| **`skills/frontend-design`** | Anthropic's design skill; the prompt tells the model to load it for any UI |
| Denied: `caveman*`, `cavecrew` skills | Cloud/token-saving skills are noise for a 3B-active model; fewer choices = better tool selection |

## Tried and rejected
- **LSP** (`"lsp": true`): OpenCode v2 doesn't run LSP diagnostics at all. Replaced by the `post-edit-check` plugin (plus the prompt rule).
- **MemPalace / memory plugins that inject context at the top**: would invalidate the prompt cache every turn.
- **Second-opinion agent on a cloud model**: declined by the user (keep everything local).
- **Lower OpenCode context limit for earlier compaction**: declined; prefer a new session per task instead.

## Working habits that keep it fast
- **One task per session.** Sessions of 250–330k tokens made every turn slow; a fresh session keeps turns fast and applies new rules from the start.
- Start big builds in the **Build** agent, not Plan.
- Keep GPU-heavy apps (games, Discord hardware acceleration) closed while the model works.

## Verify on a new machine
`.\bench-agent.ps1` runs two short OpenCode tasks and checks that the rules and tools actually work (see the script).

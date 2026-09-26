# Local LLM kit

Goal: set up (or repair) the local coding LLM on this PC quickly. Read PLAYBOOK.md first and follow it in order.
**Always start with the questions in PLAYBOOK §1a: existing model/setup to tune instead of replace? share it on the network (`-Network`, optional)? existing OpenCode (always merged, never overwritten)?**
Then:
read hardware → pick the strongest profile the hardware allows (PLAYBOOK §2) → `setup.ps1` → `tune.ps1` (MoE models) → `bench.ps1` (+ `-Full`, `bench-agent.ps1`) → turn only the one knob a failing check points to.
Do not re-benchmark alternatives listed in PLAYBOOK §6; they were measured on the reference PC and lost.
The goal and priority order are in PLAYBOOK §0; the OpenCode agent optimisations and why they exist are in AGENT.md.

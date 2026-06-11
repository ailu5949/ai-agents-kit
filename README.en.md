# ai-agents-kit — Multi-Agent Workflow Bootstrapping Scaffold

**Author**: ailu &lt;ailu5949@gmail.com&gt;
**License**: [MIT](LICENSE)
**中文文档**: [README.md](README.md)

![Multi-Agent Workflow — terminal-style diagram: $ bash install.sh --yes → 4 stages (Decompose & Analyze / Task Dispatch / Code Review / Retrospect & Memory) → Human Review OK. Inputs: Project Folder / Requirements Doc / UI Mockup. Backend Agent + Frontend Agent. Karpathy 6-Point Review. Long-term / Recent / Instant Memory. Experience Feedback Loop. MIT · multi-provider · cross-session.](docs/readme/hero.en.png)

A one-shot installable **AI collaboration harness** for your project: main Claude as the orchestrator (decomposes requirements, writes coding contracts, reviews, fixes, retrospects), with two background coding agents (Codex CLI or Claude CLI) writing code in backend / frontend respectively. You only do the final human review.

> In one sentence: turn "throw a project / a requirements doc / a UI mockup at AI and let it run end-to-end to a reviewable deliverable" into an engineered, reusable, observable workflow.

---

## Who It's For

| You are... | What this helps you with |
|---|---|
| **Someone taking over a legacy codebase** (just joined a team / inherited messy code / maintaining an old system) | Main Claude reads the code + summarizes architecture, and avoids historical pitfalls (`memory/bugs.md`) when adding features / fixing bugs |
| **Solo developer / small team** (no full test + CR pipeline, but afraid of AI writing garbage) | Forced Karpathy 6-point review + real test runs + lint + curl smoke — AI cannot "fake completion" |
| **Someone with requirements / Figma / UI mockups** (PMs / indie developers) | Drop requirements / static designs to main Claude → auto decompose into `01-需求.md` → dispatch coding agents → review → retrospect — you only click OK |
| **Heavy Claude Code / Codex CLI user** (tired of repeating prompts) | Engineered dispatch contracts (`02/03`) replace repeated prompts; state on filesystem, survives session / terminal / IDE close |
| **Someone wanting reusable lessons** (sick of stepping on the same bug across projects) | Three-layer memory (`global/{patterns,bugs}` + `projects/context` + `ideas/product-ideas`) auto-writeback; project P2 inherits P1's lessons |
| **Multi-CLI user** (codex quota exhausted, want to switch to claude) | Provider abstraction + `/retry-other-provider` one-click switch, handover.md preserves the resumption point so the new provider doesn't redo work |

**Not for**: Mature teams that already have full CI / CR / automated testing + don't need AI to write code (this tool's value is in "replacing CR / replacing test discipline"; mature teams already have better).

---

## Typical Scenarios

### 1. Take over a legacy project + add features / fix bugs

```bash
cd /path/to/legacy-project           # Codebase you don't know yet
git init                              # If no git, init first
bash /c/Users/mi/ai-agents-kit/install.sh --yes
claude .                              # Talk to main Claude in Claude Code
```

On startup, main Claude **auto-scans**: `memory/projects/context.md` (project-specific context) + `memory/global/bugs.md` (cross-project pitfalls) — reads first, then acts, won't blindly fall into known pits.

### 2. New project from scratch (requirements doc → full feature)

Drop a markdown spec (or Figma / UI static design) to main Claude:

```
You: Implement GET /api/stocks returning hot stocks, frontend /stocks page renders a table
Main Claude: decompose 01-requirements.md → (optional) 01.5-design.md + 01.6-test-cases.md
           → 02-backend.md / 03-frontend.md → dispatch backend → review → dispatch frontend → integration → retrospect
You: Just click OK at the ready-for-human checkpoints
```

See "A Complete Example" below.

### 3. Hi-fi UI mockup implementation

Provide a Figma link / HTML static design / design tokens. Main Claude writes `03-frontend.md` dispatch contract (namespace freezing / font CDN mirror / Google Fonts ban etc.), the coding agent replicates pixel-by-pixel. Review phase uses static-check grep commands + your F12 acceptance.

### 4. Long task — close IDE and go for lunch

```bash
bash .aiagents/bin/agentctl.sh up                # Start background watcher
# After dispatching, close Claude Code, go for lunch
# When coding agent finishes: desktop toast "[your-project] backend done — return to Claude Code for review"
```

### 5. Switch model / session / machine

`/handover` generates a `00-handover.md` snapshot → new session / new model reads snapshot + memory and resumes instantly. See "Upgrade / Migration".

### 6. Cross-project lesson reuse

P1 project completes → `/retrospective` auto-summarizes "what went right / what new pits we stepped in" → writes back to `memory/global/{patterns,bugs}.md` → P2 project after install **auto inherits** these lessons; new-session main Claude reads them on startup.

---

## Problems It Solves

| Pain point | Solution |
|---|---|
| Single Claude loses context / cuts corners / "fakes completion" on complex tasks | Split into **orchestrator + coding agent**: main Claude doesn't write business code (`settings.json` `permissions.deny` hard guard), only writes contracts + reviews |
| Hard to tell if Claude's "done" claim is real | **Karpathy 6 points** (A Execute / B Think / C Simplicity / D Surgical / E Goal / F Sanity) + **Pre-Human Decision Gate** (main Claude must really run tests + curl smoke + lint, all green, before you decide) |
| Want to close IDE / switch to other projects mid-task | Watcher runs persistently in background, state on filesystem (`state/current.json` + `events.jsonl`), survives across sessions |
| Coding agent finishes / fails when main Claude is offline → nobody notices | **Stop hook + Windows desktop toast** dual notification, you get pinged even when offline |
| Can't see what the sub-agent is actually doing in real time | `agentctl.sh logs <agent>` follows pretty stream (text / tool calls / result), not raw JSON spam |
| Sub-agent runs out of tokens / hits sandbox issue / rate limit mid-task | `/retry-other-provider <agent>` switches to the other (codex ↔ claude), handover.md hands off the resumption point to the new provider, no redo |
| Cross-project / cross-session lessons get lost | Three-layer **memory** (`global/{patterns,bugs}.md` / `projects/context.md` / `ideas/product-ideas.md`), read before every task + writeback after retrospect |
| Multi-bash / Cursor multi-pane: panes can't see each other's state | All state / events / heartbeats persisted to `.aiagents/state/` + `runtime/`, any terminal can `agentctl status` to query |

---

## Workflow (How It Helps You)

```
You give:  project dir / requirements doc / UI mockup
           │
           ▼
1. Decompose & Analyze (Main Claude)
   ├─ Read 4 memory files (avoid known pits)
   ├─ Produce 01-requirements.md (with acceptance criteria)
   ├─ Optional: 01.5-design.md (architecture/data model/API contract/state machine/key decisions)
   └─ Optional: 01.6-test-cases.md (TC-ID + Given/When/Then + cross-link to acceptance criteria)
           │
           ▼
2. Dispatch (Main Claude → Coding Agent)
   ├─ Produce 02-backend.md (dispatch contract)
   ├─ Produce 03-frontend.md
   └─ /dispatch-backend → watcher → agent-runner → codex/claude CLI writes code + tests + commits
           │
           ▼
3. Code Review (Main Claude, force-verify)
   ├─ Karpathy 6 points (A Execute / B Think / C Simplicity / D Surgical / E Goal / F Sanity)
   ├─ Pre-Human Decision Gate (real pytest + ruff + curl smoke + true E2E, any fail must fix)
   ├─ Fail → auto produce 04-fix.md → /bugfix-backend → redo (max 3 rounds)
   └─ Pass → state=ready-for-human
           │
           ▼
4. Report + Memory Writeback (Main Claude)
   ├─ reviews/{backend,frontend}-review.md (every review round logged)
   ├─ retrospectives/<date>-retro.md (full-cycle retrospective)
   └─ Writeback to memory/{global/patterns, global/bugs, projects/context, ideas/product-ideas}.md
           │
           ▼
You do:    Final human review (click OK / reject and have AI redo)
           Desktop toast notifies when offline — no need to babysit
```

**Future extension (low priority)**: Step 5 auto-deploy — build / deploy / smoke automatically after review passes. Not implemented; Lane deploys manually.

---

## Install

### Bash (Linux / WSL / macOS / Git Bash)

```bash
cd /d/dev/ai/workspace/your-project
git init                                                  # install.sh uses git rev-parse to locate project root
bash /c/Users/mi/ai-agents-kit/install.sh                 # Interactive
bash /c/Users/mi/ai-agents-kit/install.sh --yes           # Non-interactive (default light Python + React)
```

### PowerShell (Windows native)

```powershell
cd D:\dev\ai\workspace\your-project
git init
pwsh C:\Users\mi\ai-agents-kit\install.ps1
pwsh C:\Users\mi\ai-agents-kit\install.ps1 -BackendDir backend -Yes
```

### Stack presets (`--stack` / `-Stack`)

| Preset | Backend | Frontend |
|---|---|---|
| `python-light` (**default**) | FastAPI + SQLAlchemy + pytest + ruff | Vite + React |
| `python-poetry` | Same as above, Poetry for packaging | Same |
| `go` | Go + Gin | Vite + React |
| `node-fullstack` | Fastify | Next.js |
| `java-enterprise` | Spring Boot 3 + Maven | Vite + React |
| `java-gradle` | Spring Boot 3 + Gradle | Vite + React |

```bash
bash install.sh --yes --stack python-light       # Small project / personal first choice
bash install.sh --yes --stack java-enterprise    # Heavy enterprise
```

### Optional stage outputs (`--with-design-doc` / `--with-test-cases`)

Main Claude by default produces only `01-requirements.md` + `02/03-coding.md`. Complex projects (multi-module / multi-state-machine / cross-service) can enable two optional stages:

| Flag | Output | Content |
|---|---|---|
| `--with-design-doc` | `specs/01.5-design.md` | Architecture / data model / API contract / state machine / key decisions |
| `--with-test-cases` | `specs/01.6-test-cases.md` | Test case table (TC-ID / Given/When/Then) + edge cases + reverse-mapping to acceptance criteria |

```bash
bash install.sh --yes --with-design-doc                       # Enable design doc
bash install.sh --yes --with-design-doc --with-test-cases     # Enable both
```

PowerShell: `pwsh install.ps1 -Yes -WithDesignDoc -WithTestCases`

Once enabled, main Claude auto-produces 01 → 01.5 → 01.6 → 02/03 in order during decomposition. You can flip these flags anytime by editing `.aiagents/config.json` `workflow.{design_doc,test_cases}.enabled`, or rerun install with the flag (idempotent in-place update on installed projects, other config untouched).

---

## Dependencies

| Tool | Required | Purpose |
|---|---|---|
| `bash` 4+ or `pwsh` 5.1+ | yes | Main scripts |
| `python` 3.7+ | yes | JSON state handling |
| `git` | yes | install + watcher + agent-runner all depend on it |
| `jq` | recommended | install.sh prefers; falls back to python if missing |
| `codex` CLI or `claude` CLI | provider-dependent | Coding agent actual executor |
| `BurntToast` (PS module) | optional | Prettier Windows toast (falls back to NotifyIcon) |

---

## Common Commands

### Start / stop watcher

```bash
bash .aiagents/bin/agentctl.sh up        # One-shot start backend + frontend (true background, survives window close)
bash .aiagents/bin/agentctl.sh down      # Stop
bash .aiagents/bin/agentctl.sh restart
bash .aiagents/bin/agentctl.sh status    # See agents + provider + worker pids
```

PowerShell equivalent: `pwsh .aiagents/bin/agentctl.ps1 up|down|restart|status`

### Monitor logs

```bash
bash .aiagents/bin/agentctl.sh logs                  # List all log paths + tail-5 snapshot
bash .aiagents/bin/agentctl.sh logs backend          # Follow backend (pretty stream by default)
bash .aiagents/bin/agentctl.sh logs both             # Follow backend + frontend simultaneously
bash .aiagents/bin/agentctl.sh logs backend worker   # Follow watcher itself (check if watcher is alive)
bash .aiagents/bin/agentctl.sh logs backend raw      # Raw JSON Lines (debug)
```

### Cost + diagnostics (v3.6)

```bash
bash .aiagents/bin/agentctl.sh cost      # Token cost summary: cost($)/tokens/turns by date × agent + today/cumulative totals
bash .aiagents/bin/agentctl.sh doctor    # One-shot diagnosis: watcher alive / heartbeat / state / log activity / pending signals + per-agent advice
```

`cost` aggregates `total_cost_usd` from claude tasks' `.log.raw` files (codex tasks expose token counts only, no dollar value). `doctor` scripts the evidence-gathering part of the timeout SOP — when a task seems stuck, run it first and follow the 💡 advice.

### Mobile push notification (v3.6 — get pinged even away from your desk)

Edit `notify.push` in `.aiagents/config.json`; done / failed / timeout events push to your phone:

```json
{
  "notify": {
    "push": {
      "provider": "ntfy",
      "key": "",
      "url": "https://ntfy.sh/my-secret-topic",
      "events": ["done", "failed", "timeout", "stale"]
    }
  }
}
```

| provider | Channel | What to fill |
|---|---|---|
| `serverchan` | WeChat (Server酱, [sct.ftqq.com](https://sct.ftqq.com)) | `key` = SendKey |
| `pushplus` | WeChat (PushPlus) | `key` = token |
| `bark` | iOS native push | `key` = device key; `url` for self-hosted server |
| `ntfy` | Android / self-hosted | `url` = full topic URL (e.g. `https://ntfy.sh/my-topic`) |

Empty `provider` = off (default). Push failures are silent and never block the main flow; desktop toast keeps working. Manual test: `bash .aiagents/bin/notify-push.sh backend done "test" myproject`.

### Slash commands inside Claude Code

| Command | Purpose |
|---|---|
| `/dispatch-backend` | Dispatch backend task. Accepts `--provider claude --model sonnet --timeout 3600` |
| `/dispatch-frontend` | Dispatch frontend task |
| `/bugfix-backend` / `/bugfix-frontend` | Dispatch fix (uses 04-fix.md) |
| `/status` | Check agent status |
| `/review` | Manually trigger review (fallback; normally auto-injected by Stop hook) |
| `/memory "<note>"` | Write a memory item to `memory/global/patterns.md` or `bugs.md` |
| `/retrospective` | Full-cycle retrospective, writeback to memory |
| `/handover` | Generate state snapshot before switching session / model |
| `/retry-other-provider <agent>` | On failure, switch to the other provider (handover skeleton auto-generated) |
| `/release-without-verify <agent> "<reason>"` | Emergency bypass of the real-verify gate (auto-writes to bugs.md) |

### Per-agent model selection (main Opus + sub Sonnet typical combo)

Edit `.aiagents/config.json`:

```json
{
  "agents": {
    "backend":  {"dir": "backend",  "provider": "claude", "model": "sonnet"},
    "frontend": {"dir": "frontend", "provider": "claude", "model": "sonnet"}
  }
}
```

Main Claude's own model is controlled by Claude Code client (`claude --model opus .` or `/model opus`), unrelated to the kit.

---

## A Complete Example

Scenario: implement `GET /api/stocks` endpoint + frontend table page

```text
# Terminal 1: start watcher
bash .aiagents/bin/agentctl.sh up

# Terminal 2: follow live logs (optional, for monitoring)
bash .aiagents/bin/agentctl.sh logs both

# Terminal 3: start Claude Code
claude .

────────────────────────────────────────────────────────
You → Claude (in Claude Code panel):
    Implement GET /api/stocks returning hot stocks, frontend /stocks page table

Claude:
    1. Read memory (patterns / bugs / context / ideas)
    2. Produce docs/ai-agents/specs/01-requirements.md (with acceptance criteria)
    3. Wait for your confirm

You: Confirm 01, continue to coding contract

Claude:
    Produce docs/ai-agents/specs/02-backend.md
    Produce docs/ai-agents/specs/03-frontend.md
    Wait for your confirm

You: Dispatch backend

Claude: Invoke /dispatch-backend
    → watcher detects signal → agent-runner starts codex/claude
    → Writes code + tests + commit in backend dir
    → On completion: state.backend.state = done-awaiting-review
    → Desktop toast: "[your-project] backend done — return to Claude Code for review"

You: Return to Claude (next message triggers Stop hook injecting "backend done, please review")

Claude:
    Run Karpathy 6 points review
    Run Pre-Human Decision Gate (pytest + ruff + curl smoke)
    All pass → write reviews/backend-review.md + state=ready-for-human
    Any fail → produce 04-fix-backend.md → /bugfix-backend (max 3 rounds)

You: Dispatch frontend → ...same flow...

Finally integration passes → /retrospective writes back lessons to memory
```

---

## Core Design

- **Trigger**: slash command (`/dispatch-*`) → `agentctl.sh dispatch <agent>` writes signal + event, NOT natural-language trigger words
- **Execution chain**: `signal → watch-agent.sh → agent-runner.sh → provider(codex/claude) → state + event`
- **State authority**: `.aiagents/state/current.json` `<agent>.state` field (not signal files, not log, not events.jsonl)
- **Review**: Karpathy 6 points (A Execute / B Think / C Simplicity / D Surgical / E Goal / F Sanity) + Pre-Human Decision Gate (real test / curl / lint must all pass)
- **Failure handoff**: `/retry-other-provider <agent>` switches to the other (codex ↔ claude), `runtime/<agent>-handover.md` carries the resumption point, no redo
- **Memory**: `memory/{global,projects,ideas}/*.md` three layers, must-read before tasks, writeback after retro
- **Notification**: Stop hook (in-session) + desktop toast (cross-session / offline) dual layer

---

## Directory Layout

```
ai-agents-kit/                           # Tool repo (this dir)
├── install.sh / install.ps1
├── README.md (Chinese) / README.en.md (English)
├── LICENSE
├── templates/                           # Materials install copies / merges into the target project
│   ├── CLAUDE.md                        # Main Claude directive (marker block sync'd)
│   ├── .claude/{settings.json, commands/}    # Stop hook + 11 slash commands
│   └── .aiagents/
│       ├── bin/                         # agentctl / agent-runner / watch-agent / providers/ / stop-notify / notify-toast
│       ├── memory/                      # global / projects / ideas
│       └── prompts/                     # dispatch-preamble.md
├── scripts/                             # fix-claude-md.py and other repair scripts
├── docs/                                # Tool's own design docs
└── companion/                           # Tauri desktop pet (independent track, optional)

your-project/                            # After install — target project layout
├── .aiagents/
│   ├── config.json                      # Main config (provider / agent dir / model / commands)
│   ├── bin/                             # Sync'd from templates above
│   ├── signals/                         # task_ready_* / *_done / *_failed / *_timeout
│   ├── logs/                            # be_<date>.log / fe_<date>.log / worker-*.log
│   ├── state/                           # current.json + events.jsonl
│   ├── runtime/                         # workers.json + heartbeats/ + archive/
│   └── memory/                          # Three-layer memory
├── .claude/                             # Stop hook + slash commands
├── CLAUDE.md                            # Marker block sync'd by kit
└── docs/ai-agents/
    ├── specs/                           # 01 requirements / 02 backend / 03 frontend / 04 fix / 00 handover
    ├── reviews/                         # backend-review.md / frontend-review.md
    └── retrospectives/                  # Retrospective
```

---

## Upgrade / Migration

### Upgrade installed project to a new version

```bash
cd /path/to/your-project
bash /c/Users/mi/ai-agents-kit/install.sh --yes
```

install.sh is idempotent: infra scripts refresh, `config.json` / `memory/*.md` / `specs/*` / manually-edited parts are preserved.

### Migrate to another machine

```bash
# 1. Push tool repo to GitLab / GitHub; clone on new machine
cd C:/Users/mi/ai-agents-kit && git push origin master

# 2. Business project is just a normal git repo, push + clone normally

# 3. Install deps on new machine (see "Dependencies" above)
# 4. After cloning, rerun install.sh in the new project location to refresh infra scripts
bash /new/path/to/ai-agents-kit/install.sh --yes
```

`codex` / `claude` tokens are user-level config; you need to `codex auth login` / `claude login` again on the new machine.

---

## Relation to ai-multi-agents Web Console

The schemas of `state/current.json` + `events.jsonl` + `runtime/heartbeats/*` are compatible with the console in `D:\dev\ai\ai-multi-agents\`, which can independently plug in for visualization. The kit itself does not bundle a console.

---

## References

This tool's design is inspired by the following resources:

1. **Harness Engineering: Leveraging Codex in an Agent-First World** (OpenAI) — [https://openai.com/index/harness-engineering/](https://openai.com/index/harness-engineering/)
2. **Karpathy-Inspired Claude Code Guidelines** (multica-ai) — [https://github.com/multica-ai/andrej-karpathy-skills](https://github.com/multica-ai/andrej-karpathy-skills)

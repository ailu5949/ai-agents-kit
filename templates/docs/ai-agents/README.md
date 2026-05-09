# 三 Agent 协作工作流 — 操作手册 (v2)

> 本手册由 **ai-agents-kit v2** 安装。使用前请确认 `.aiagents/config.json` 里的目录和命令已改成你项目的值。

## 角色分工

| 角色 | 做什么 | 沟通对象 |
|------|--------|---------|
| **你** | 提需求 / 审核产物 / 点击 go | 只跟 Claude 说话 |
| **Claude Code** | 拆需求 / 写编码指引 / 派活 / 审查 / 写修复单 / 复盘 / 写记忆 | 你 + signal/state |
| **Codex-Backend** | 根据 02 指引在后端目录写代码 | signal |
| **Codex-Frontend** | 根据 03 指引在前端目录写代码 | signal |

## 产物编号

| 文件 | 产出者 | 说明 |
|------|--------|------|
| `specs/01-需求.md` | Claude | 需求拆解 + 验收标准 |
| `specs/02-后端编码.md` | Claude | 给后端 Codex 的指令单 |
| `specs/03-前端编码.md` | Claude | 给前端 Codex 的指令单 |
| `specs/04-Bug修复-backend.md` | Claude | 审查失败时生成 |
| `specs/04-Bug修复-frontend.md` | Claude | 审查失败时生成 |
| `reviews/backend-review.md` | Claude | 每轮后端审查追加一段 |
| `reviews/frontend-review.md` | Claude | 每轮前端审查追加一段 |
| `retrospectives/<日期>-retro.md` | Claude | 完整需求结束后的复盘 |
| `specs/00-交接.md` | Claude | 切换模型前生成 |

## v2 执行链(必须显式)

```
signal → watch-agent.sh → agent-runner.sh → codex → state/event
```

- `signal`(`.aiagents/signals/*`)只是触发器
- `.aiagents/state/current.json` 才是状态权威
- `.aiagents/state/events.jsonl` 是事件流(给调试 + 外部 Web Console 用)

## 启动方式(两选一,可混用)

### 方案 ① tmux 一屏分屏(Linux/WSL)

```bash
cd <项目根>
bash ./start-agents.sh
```

屏幕变成三窗格:上 Claude,左下 Codex-BE,右下 Codex-FE。

### 方案 ② Cursor / VSCode 三终端面板(推荐 Windows)

```
面板 1> claude .
面板 2> bash .aiagents/bin/agentctl.sh watch backend
面板 3> bash .aiagents/bin/agentctl.sh watch frontend
```

PowerShell 等价:

```
面板 2> pwsh .aiagents\bin\agentctl.ps1 watch backend
面板 3> pwsh .aiagents\bin\agentctl.ps1 watch frontend
```

## 日常使用流程(11 步,含复盘)

1. 启动 3 个 agent(方案①或②)
2. 在 Claude 面板说需求:"实现一个 /stocks 接口,前端加一个列表页"
3. **Claude 先读 memory**(`.aiagents/memory/global/{patterns,bugs}.md` 等)
4. Claude 产 `specs/01-需求.md` → 你确认
5. Claude 产 `specs/02-后端编码.md` → 你审阅,确认
6. Claude 产 `specs/03-前端编码.md` → 你审阅,确认
7. 你说"派后端"(或 `/dispatch-backend`)→ watcher 调度 runner → 产生日志 + 状态/事件
8. Codex-BE 完成 → state.backend.state 变成 `done-awaiting-review` → 你下次给 Claude 发消息时,Stop hook 自动注入"后端完成,请审查"
9. Claude 走 Karpathy 6 项审查 → 追加 `reviews/backend-review.md` → 通过或生成 `04-Bug修复-backend.md`
10. 通过则你说"派前端",进入前端循环;不通过 Claude 自动 `/bugfix-backend`(最多 3 轮)
11. 前端走完 + 联调通过后 → `/retrospective` 复盘 + 把经验写回 `.aiagents/memory/`

任何时候你可以手动敲:
- `/status` — 查看三 agent 现况
- `/review` — 手动重审(兜底)
- `/memory "<经验>"` — 写一条记忆

## Memory 系统

```
.aiagents/memory/
├── global/
│   ├── patterns.md      # 跨项目"做对了"
│   └── bugs.md          # 跨项目踩过的坑
├── projects/
│   └── context.md       # 本项目独有
└── ideas/
    └── product-ideas.md # 产品想法库
```

Claude 每次新会话/新需求开始前会读这四份。失败和成功经验自动累积,新项目接手时不用从零开始。

## 监理机制(Karpathy 6 项)

Claude 审查 Codex 产出时**必须**走完 6 项(详见项目根 `CLAUDE.md`):

1. **A 执行验证** — 读日志 + state/events + git diff
2. **B Think** — 对照 02/03 + 对照 bugs.md
3. **C Simplicity** — 没有 YAGNI 违反
4. **D Surgical** — 没有顺手改无关代码
5. **E Goal-Driven** — 实际跑测试和 lint
6. **F Sanity** — 框架一致性(Vite + React 必备 plugin、Spring Boot 必备 starter 等)

任何一项失败 → 整体失败 → 生成 04 修复单。

## 排错

| 现象 | 排查 |
|------|------|
| `/dispatch-backend` 报"规格文件不存在" | 先让 Claude 产出 `specs/02-后端编码.md` |
| Stop hook 不触发 | 看 `.claude/settings.json` 里 hooks.Stop 是否指向 `.aiagents/bin/stop-notify.sh` |
| state.json 不更新 | 看 watcher 终端是否还活着;`bash .aiagents/bin/agentctl.sh status` 强刷一次 |
| Codex 完成了但 Claude 没收到提醒 | Stop hook 在**下一次**你发消息时生效;先敲 `/status` 确认 |
| 连续失败 3 次后停了 | `cat .aiagents/state/current.json` 看 state 字段;查 `.aiagents/logs/` 找原因 |
| 信号乱了想从头再来 | `rm .aiagents/signals/* -f`(`.consumed_*` 一并清) |
| Cursor 终端中文乱码 | `chcp 65001`(PowerShell)/ `export LANG=zh_CN.UTF-8`(bash) |

## 从 v1 升级

如果项目原本是按 ai-agents-kit v1 装的(目录是 `docs/superpowers/`):

```bash
bash /path/to/ai-agents-kit/install.sh --migrate-v1
# 或 PowerShell:
pwsh \\path\\to\\ai-agents-kit\\install.ps1 -MigrateV1
```

迁移脚本会:
- `docs/superpowers/specs/*` → `docs/ai-agents/specs/*`
- `docs/superpowers/signals/*` → `.aiagents/signals/*`
- `docs/superpowers/logs/*` → `.aiagents/logs/*`
- 备份旧 `bin/` 后删除
- CLAUDE.md 的 v1 marker 段升级为 v2
- 留 `docs/superpowers/MIGRATED.md` 提示已迁移

迁移后可以安全删除 `docs/superpowers/`。

## 目录约定

```
<项目根>/
├── .aiagents/                       # 运行时数据 + 脚本 + 记忆
│   ├── config.json                  # JSON 配置(主)
│   ├── bin/                         # agentctl.sh / agent-runner.sh / watch-agent.sh / stop-notify.sh / *.ps1 / filter-output.sh / wait-signal.sh
│   ├── signals/                     # task_ready_* / *_done / *_failed / *_timeout
│   ├── logs/                        # be_<date>.log / fe_<date>.log / worker-*.log
│   ├── state/                       # current.json + events.jsonl
│   ├── runtime/                     # workers.json + heartbeats/<agent>.json
│   └── memory/                      # global / projects / ideas
├── .claude/                         # Claude Code 配置
│   ├── settings.json                # Stop hook 注册 + permissions.allow
│   ├── agents.conf                  # KV 配置(向后兼容,被 v1 脚本 source)
│   └── commands/                    # 9 个 slash command
├── CLAUDE.md                        # Claude 主指令(v2 marker)
├── start-agents.sh                  # tmux 启动脚本
└── docs/ai-agents/
    ├── specs/                       # 01~04 + 00-交接
    ├── reviews/                     # 后端 + 前端审查
    └── retrospectives/              # 复盘报告
```

## 配置入口对比

| 项 | v1 旧位置 | v2 新位置 |
|----|----------|----------|
| Claude 主指令 | CLAUDE.md `<!-- ai-agents-kit:start v1 -->` | CLAUDE.md `<!-- ai-agents-kit:start v2 -->` |
| 项目配置 | `.claude/agents.conf`(KV) | `.aiagents/config.json`(JSON,主) + `.claude/agents.conf`(KV,fallback) |
| 状态判断 | `docs/superpowers/signals/*` 文件存在性 | `.aiagents/state/current.json` 的 `state` 字段 |
| 事件流 | 没有 | `.aiagents/state/events.jsonl` |
| 记忆 | 没有 | `.aiagents/memory/` 三层 |
| 复盘 | 没有 | `docs/ai-agents/retrospectives/` |

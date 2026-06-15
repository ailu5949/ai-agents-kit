# 多Agent协作工作流初始化脚手架

> 本手册由 **ai-agents-kit** 安装。使用前请确认 `.aiagents/config.json` 里的目录和命令已改成你项目的值。

## 角色分工

| 角色 | 做什么 | 沟通对象 |
|------|--------|---------|
| **你** | 提需求 / 审核产物 / 点击 go | 只跟 Claude 说话 |
| **Claude Code** | 拆需求 / 写编码指引 / 派活 / 审查 / 写修复单 / 复盘 / 写记忆 | 你 + signal/state |
| **Backend 编码 agent** | 根据 02 指引在后端目录写代码 | signal |
| **Frontend 编码 agent** | 根据 03 指引在前端目录写代码 | signal |

## 产物编号

| 文件 | 产出者 | 触发条件 | 说明 |
|------|--------|---------|------|
| `specs/01-需求.md` | Claude | 永远 | 需求拆解 + 验收标准 |
| `specs/01.5-设计.md` | Claude | `workflow.design_doc.enabled` | **可选** · 架构 / 数据模型 / 接口契约 / 状态机 / 关键决策 |
| `specs/01.6-测试用例.md` | Claude | `workflow.test_cases.enabled` | **可选** · 用例表(TC-ID / Given/When/Then)+ 边界条件 + 反向对齐验收点 |
| `specs/02-后端编码.md` | Claude | 永远 | 给后端编码 agent 的指令单(引用 01.5 / 01.6 不重抄) |
| `specs/03-前端编码.md` | Claude | 永远 | 给前端编码 agent 的指令单 |
| `specs/04-Bug修复-backend.md` | Claude | 审查失败 | 修复指令单 |
| `specs/04-Bug修复-frontend.md` | Claude | 审查失败 | 修复指令单 |
| `reviews/backend-review.md` | Claude | 每轮审查 | 追加一段,不覆盖历史 |
| `reviews/frontend-review.md` | Claude | 每轮审查 | 追加一段 |
| `retrospectives/<日期>-retro.md` | Claude | 完整需求结束 | 复盘 + 回写 memory |
| `specs/00-交接.md` | Claude | `/handover` | 切换模型/会话前的状态快照 |

> **开启可选产物**:在 `install.sh` 加 `--with-design-doc --with-test-cases`,或编辑 `.aiagents/config.json` 的 `workflow.design_doc.enabled` / `workflow.test_cases.enabled`。默认两个都关,适合小需求 / Demo;复杂需求(多模块 / 多状态机 / 跨服务)建议开启。

## v2 执行链(必须显式)

```
signal → watch-agent.sh → agent-runner.sh → codex → state/event
```

- `signal`(`.aiagents/signals/*`)只是触发器
- `.aiagents/state/current.json` 才是状态权威
- `.aiagents/state/events.jsonl` 是事件流(给调试 + 外部 Web Console 用)

## 启动方式

后台 watcher + Cursor / VSCode / 任意终端的多面板布局:

```bash
# 面板 1 — 主 Claude
claude .

# 面板 2 — 起 watcher + 直接跟双 agent 日志 (一条命令搞定, 省得再敲 logs both)
bash .aiagents/bin/agentctl.sh up logs
#   纯起 watcher 不跟日志:  bash .aiagents/bin/agentctl.sh up
#   起 watcher + 编码 + 对抗审查全跟: bash .aiagents/bin/agentctl.sh up logs all
```

PowerShell 等价:

```powershell
pwsh .aiagents\bin\agentctl.ps1 up logs
```

`up logs` 起完 watcher 立即进入跟随,Ctrl+C 只停跟随、watcher 仍后台。停 watcher:`agentctl.sh down`(或 `agentctl.ps1 down`)。

> v3.5+ 起不再支持 tmux 一屏分屏方式(`start-agents.sh`)。已装项目重跑 install 会自动备份遗留的 `start-agents.sh` 到 `.deprecated.*`。

## 日常使用流程(11 步,含复盘)

1. 启动主 Claude + 后台 watcher(见上方"启动方式")
2. 在 Claude 面板说需求:"实现一个 /stocks 接口,前端加一个列表页"
3. **Claude 先读 memory**(`.aiagents/memory/global/{patterns,bugs}.md` 等)
4. Claude 产 `specs/01-需求.md` → 你确认
5. Claude 产 `specs/02-后端编码.md` → 你审阅,确认
6. Claude 产 `specs/03-前端编码.md` → 你审阅,确认
7. 你说"派后端"(或 `/dispatch-backend`)→ watcher 调度 runner → 产生日志 + 状态/事件
8. Backend 编码 agent 完成 → state.backend.state 变成 `done-awaiting-review` → 你下次给 Claude 发消息时,Stop hook 自动注入"后端完成,请审查"
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

Claude 审查编码 agent 产出时**必须**走完 6 项(详见项目根 `CLAUDE.md`):

1. **A 执行验证** — 读日志 + state/events + git diff
2. **B Think** — 对照 02/03 + 对照 bugs.md
3. **C Simplicity** — 没有 YAGNI 违反
4. **D Surgical** — 没有顺手改无关代码
5. **E Goal-Driven** — 实际跑测试和 lint
6. **F Sanity** — 框架一致性(Vite + React 必备 plugin、Spring Boot 必备 starter 等)

任何一项失败 → 整体失败 → 生成 04 修复单。

## 对抗性审查(可选,v3.7)

`workflow.adversarial_review.enabled == true` 时,真打验证(Pre-Human Gate)全过后多一道:用**异构 provider**(默认 codex)独立"找茬",防主 Claude 同体审查盲区(既写 02/03 又审,理解偏了会按同样偏的判 pass)。

```bash
# 主 Claude 跑(真打验证通过后):
/adversarial-review backend
# 背后: bash .aiagents/bin/adversarial-review.sh backend
```

- reviewer 独立读 spec + 本轮 git diff,默认有罪,落报告 `reviews/adversarial-<agent>-<ts>.md`,末行 `VERDICT: PASS|FAIL`
- 主 Claude 是仲裁者:PASS → ready-for-human;FAIL → 逐条核实 → 04 修复 → 派回
- **不是常驻 watched agent**:主 Claude 在验证关卡一次性拉起 codex(不走 watcher 流水线)
- **实时看找茬过程**:`agentctl.sh logs review`(或 `logs all` 编码+审查一窗),写稳定路径 `.aiagents/logs/adversarial-<agent>.log`
- 开启:`install.sh --with-adversarial-review` 或改 `config.json workflow.adversarial_review.enabled`
- 异构性:编码用 claude → reviewer 用 codex(反之亦然),相同会警告

## 成本 + 诊断(v3.6)

```bash
bash .aiagents/bin/agentctl.sh cost      # token 成本汇总(claude 任务的 total_cost_usd 聚合)
bash .aiagents/bin/agentctl.sh doctor    # 一键诊断: watcher/心跳/state 卡点/log 活性 + 建议动作
```

## 移动端推送(v3.6)

编辑 `.aiagents/config.json` `notify.push`(provider 留空 = 关):

- `serverchan`(微信 Server酱,`key`=SendKey)/ `pushplus`(微信,`key`=token)
- `bark`(iOS,`key`=device key)/ `ntfy`(安卓/自建,`url`=topic 地址)

任务 done/failed/timeout/stale 自动推手机;失败静默不影响主流程。
手测:`bash .aiagents/bin/notify-push.sh backend done "测试" myproject`

## 排错

**第一步永远是 `bash .aiagents/bin/agentctl.sh doctor`** — 它会列出 watcher 存活 / 心跳 / state 卡点 / 日志活性,并给每个 agent 一条建议动作。下表是 doctor 覆盖不到的场景:

| 现象 | 排查 |
|------|------|
| `/dispatch-backend` 报"规格文件不存在" | 先让 Claude 产出 `specs/02-后端编码.md` |
| Stop hook 不触发 | 看 `.claude/settings.json` 里 hooks.Stop 是否指向 `.aiagents/bin/stop-notify.sh` |
| state.json 不更新 | 看 watcher 终端是否还活着;`bash .aiagents/bin/agentctl.sh status` 强刷一次 |
| 编码 agent 完成了但 Claude 没收到提醒 | Stop hook 在**下一次**你发消息时生效;先敲 `/status` 确认 |
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

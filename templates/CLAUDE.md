# 三 Agent 协作工作流 — 项目级指令

> 本节由 **ai-agents-kit** 安装,请勿手动编辑开头的 5 行 marker。如要升级请重跑 `install.sh` 或 `install.ps1`。
> <!-- ai-agents-kit:start v2 -->

## 新会话/切换模型后的启动规程

**每次启动新会话(包括切换到 DeepSeek 或其他模型后)**,必须先执行以下检查:

1. `ls docs/ai-agents/specs/00-交接.md 2>/dev/null && cat docs/ai-agents/specs/00-交接.md` — 如果存在,优先阅读
2. **读 memory**(每次任务开始前必读,4 份):
   - `.aiagents/memory/global/patterns.md` — 跨项目成功模式
   - `.aiagents/memory/global/bugs.md` — 跨项目踩过的坑
   - `.aiagents/memory/projects/context.md` — 本项目独有上下文
   - `.aiagents/memory/ideas/product-ideas.md` — 产品想法库
3. `/status` — 确认 `.aiagents/state/current.json` 实时状态
4. 如有交接文件,按其中"立即下一步操作"执行;如无,正常等待用户指令

> **切换模型说明**: 如果 token 耗尽需要换模型,在旧会话执行 `/handover` 生成状态快照。新模型读 `00-交接.md` + memory 即可无缝接管。如新模型不支持 slash command(如 DeepSeek 直接 API),直接读 00-交接.md 手动执行等价 bash 命令。

---

## 你的角色

你是 **Claude Code 主角色**,是用户(16 年 IT / Java 后端)的**唯一沟通入口**。职责:
1. 拆解用户需求 → `docs/ai-agents/specs/01-需求.md`
2. 生成后端编码指引 → `docs/ai-agents/specs/02-后端编码.md`
3. 生成前端编码指引 → `docs/ai-agents/specs/03-前端编码.md`
4. 审查编码 agent 交付物 → `docs/ai-agents/reviews/backend-review.md` / `frontend-review.md`
5. 审查失败时生成修复指令 → `docs/ai-agents/specs/04-Bug修复-{backend|frontend}.md`
6. 完整需求结束后复盘 → `docs/ai-agents/retrospectives/<YYYY-MM-DD>-retro.md` + 写回 memory

**你不直接写业务代码**。业务代码由两个编码 agent 执行:
- Backend 编码 agent 在 `<BACKEND_DIR>`(见 `.aiagents/config.json` 或 `.claude/agents.conf`)
- Frontend 编码 agent 在 `<FRONTEND_DIR>`

## 触发编码 agent 的方式

永远用 slash command,**不要**用自然语言触发词,**不要**自己手写信号文件:

| 场景 | 命令 |
|------|------|
| 派后端任务 | `/dispatch-backend` |
| 派前端任务 | `/dispatch-frontend` |
| 派后端修复 | `/bugfix-backend` |
| 派前端修复 | `/bugfix-frontend` |
| 查 agent 状态 | `/status` |
| 手动触发审查 | `/review` |
| 写一条经验记忆 | `/memory` |
| 完整需求复盘 | `/retrospective` |
| 生成交接文档(换模型前) | `/handover` |

slash 命令背后是 `bash .aiagents/bin/agentctl.sh ...`(PowerShell 等价 `pwsh .aiagents/bin/agentctl.ps1 ...`),由它写信号文件 + 状态 + 事件流,保证所有路径和时间戳正确。

## v2 执行链(必须显式)

```
signal → watch-agent.sh → agent-runner.sh → codex → state/event
```

- `signal`(`.aiagents/signals/*`)只是**触发器**,不是状态权威
- `.aiagents/state/current.json` 才是**当前状态唯一来源**
- `.aiagents/state/events.jsonl` 是事件流水(给调试和外部 Web Console 用)
- `watch-agent.sh` 只监听信号并把任务交给 runner,**不直接调用编码 agent**
- `agent-runner.sh` 是 Bash 路径下唯一的 编码 agent 执行入口,负责 timeout、日志、失败捕获、写 done/failed/timeout 信号、写状态和事件

## 阶段顺序与门控

严格按这个顺序推进,每完成一阶段产物落盘后**暂停并与用户确认**:

1. **阶段 01 — 需求拆解**: 与用户对话,产出 `01-需求.md`(含验收标准)
2. **阶段 02/03 — 编码指引**: 产出 `02-后端编码.md` 和 `03-前端编码.md`,两份可并行产出,但要让后端指引里包含需要暴露的接口清单,前端指引里引用这些接口作为依赖
3. **阶段 派后端**: 用户确认后,执行 `/dispatch-backend`
4. **阶段 审查后端**: Stop hook 检测到 `state.backend.state == done-awaiting-review` 时会在下一个 turn 注入提醒,届时按 **Karpathy 审查 rubric** 审查,产出或追加 `reviews/backend-review.md`
5. **阶段 派前端**: 后端审查通过后,执行 `/dispatch-frontend`
6. **阶段 审查前端**: 同后端
7. **阶段 联调 + 复盘**: 告知用户手工联调;联调通过后执行 `/retrospective`

失败路径: 任何阶段审查不通过,生成 `04-Bug修复-{backend|frontend}.md`,执行对应 `/bugfix-*`,编码 agent 修复后回到审查阶段,最多循环 3 次(`MAX_RETRY=3`),仍失败则向用户求助。

## ⛔ 审查触发 — 硬约束(别绕过)

> 历史教训:曾经有一次 Claude 在 编码 agent 还在跑的时候就"主动"审查了,看到的是半成品文件,审查通过 ✅,结果 编码 agent 后来又改了 App.jsx,Claude 的 ✅ 其实是对过时内容打的分。从此以后:

**审查的合法触发源只有两个**:
1. **Stop hook** 在 `system-reminder` / 对话内容里明确告诉你 "检测到 backend/frontend done,请审查"
2. 用户**显式**敲 `/review` slash 命令

**判断状态用 `state/current.json`,不用 signals 不用 log**:
- `state.backend.state == "done-awaiting-review"` → 可以审查后端
- `state.frontend.state == "done-awaiting-review"` → 可以审查前端
- 任何其他状态(running / queued / failed / timeout / idle)→ **不能**审查

**严禁的行为**(出现一次都是 bug):
- ❌ 用户刚说"派后端"就开始写审查报告 — 编码 agent 还没跑
- ❌ 用户问"编码 agent 应该好了吧?" 你就去审查 — 应该答:"我看 `.aiagents/state/current.json`,backend.state 是 X,不是 done-awaiting-review,不能审查"
- ❌ 看到代码文件已经存在就开始审查 — 文件存在 ≠ 编码 agent 已结束
- ❌ 自己用 Bash 读 `*_done` 来"替 Stop hook 判断" — Stop hook 是唯一判定方;state.json 是唯一状态来源
- ❌ 凭 `events.jsonl` 推测进度 — 那只是事件流,可能滞后于 state 也可能超前

**判断通过 Stop hook 是否已触发**:如果你上一条消息的开头有一段 `[Stop hook] 检测到 编码 agent 状态变化: - ✅ backend 开发完成,请立即审查...` 那就是 Stop hook 注入了。没有这段 = 没触发 = 不准审查。

## ⛔ provider 同源审查纪律 (multi-provider 后)

历史教训: 编码 agent 与主 Claude 异构,审查无"同根偏向"风险。
multi-provider 后编码 agent 可选 Claude Code(同模型不同会话),你和它对你而言仍是"外部 agent",规则不变:

- ❌ 严禁因"反正都是 Claude"放松审查 — Karpathy 6 项与编码 agent 派单时同等严格
- ❌ 严禁用"它应该是这样想的"代替"git diff 实际证据"
- ❌ 严禁"顺手帮一下"自己改代码 — 编码 agent 失败仍走 04 修复 → 重派,不论 provider
- ✅ 你只看 state.json + events.jsonl + git diff + log + commit message — 不能假设编码 agent 的 thinking
- ✅ 审查报告必须写明 `**Provider**: codex | claude` 字段(由你写,不依赖 events.jsonl)

## ⛔ Pre-Human Decision Gate (人工决策前必经关卡)

**三段式工作流**:

```
编码 agent 完成 → state=done-awaiting-review
       ↓ 主 Claude 走 Karpathy 6 项审查
state=claude-verifying ← 主 Claude **真打**跑测试 + curl smoke + E2E
       ↓ 全过
state=ready-for-human ← Lane 拍板:收下 / 打回 / 推迟
```

**done-awaiting-review 不再直接交人工**。审查通过后必须:

1. 写 `state=claude-verifying`(主 Claude 用 Bash 直接编辑 `.aiagents/state/current.json`)
2. 跑下表所有项(命令从 `.aiagents/config.json` `agents.<a>.test_cmd / lint_cmd / smoke_endpoints` 读)
3. 任一失败 → 04-Bug修复 → 派编码 agent → 回起点
4. 全过 → 写 `state=ready-for-human` + 通知 Lane

**验证清单**:

| 类别 | 命令 | 通过判据 |
|---|---|---|
| 后端测试 | `cd $BACKEND_DIR && $TEST_CMD` | exit 0 + 测试数 ≥ spec 验收 + 无 regression |
| 后端 lint | `cd $BACKEND_DIR && $LINT_CMD` | exit 0 |
| 后端 import | `$IMPORT_CHECK` | "OK" + 无 ImportError |
| 接口 smoke | `curl -fsS $ENDPOINT` × N | 全 200 + 含 spec 要求字段 |
| 真 E2E | `$E2E_CMD`(项目自定义) | exit 0 + 行数验证 + 数据形状 |
| 前端构建 | `cd $FRONTEND_DIR && $BUILD_CMD` | exit 0 + dist 产物存在 |
| 前端 lint | `cd $FRONTEND_DIR && $LINT_CMD` | exit 0 |
| 前端 file:// smoke | `agents.frontend.smoke_grep` 各项 | 全部命中预期值 |

**任一 stdout/stderr 含** `error|fail|exception|traceback|sandbox|forbidden|denied|connection refused`(case-insensitive)→ 主 Claude 必须解释,不能略过。

**审查报告必含 § 真打验证段**(模板):

```markdown
### § 真打验证 (Pre-Human Decision Gate)

| 验证项 | 命令 | exit | 输出尾 5 行 | 通过 |
|---|---|---|---|---|
| BE 测试 | `pytest -q` | 0 | `... 86 passed in 12.3s` | ✅ |
| BE lint | `ruff check .` | 0 | `All checks passed!` | ✅ |
| ... | ... | ... | ... | ... |

**全部 ✅ → state 推进 ready-for-human**
```

**报告未含此段 = 报告无效**(主 Claude 不能"忘了跑")。

**应急 bypass**: Lane 显式 `/release-without-verify <agent> "<reason>"` 可绕过 — 但每次破例自动写入 `bugs.md` 留痕。

**主 Claude 运维边界**: 跑测试 / 跑接口 / kill 进程 / 起 server **可做**(运维操作);Edit / Write 业务代码 **严禁**(由 settings.json deny 强制)。

## ⛔ 副 agent 超时诊断流程 (Timeout Triage SOP)

**触发**: state.<agent>.state == "timeout"(由 Stop hook 注入"⏰ ${kind} 超时"提示;Stop hook 已自动跑诊断附在 reason 里,主 Claude 直接读)。

**自动诊断已注入**(主 Claude 不用再手动跑):
- 工作目录 + HEAD commit
- git status(工作树是否有改动)
- log 末尾 10 行
- 决策树提示

**主 Claude 决策树**:

| 现象 | 解读 | 行动 |
|---|---|---|
| git 有未提交改动 / 新 commit + log 末尾正常 | work 已落, timeout 是收尾延迟(adapter 已自动走 stale 路径,但若仍报 timeout 需手动诊断) | **代 commit**(`cd <agent_dir> && git add <files> && git commit -m "..."`)+ 走 Karpathy 审查 + verify gate |
| git 干净 + log 末尾仍在打印动作行(🔧/💬) | claude/codex 仍在跑, runner 1800s 内部 timeout 截断 | 等下一轮 Stop hook(子进程会继续 → 写 done 信号)/ 或敲 `/dispatch-<agent>` 重派让 timeout 重置 |
| git 干净 + log 末尾报错(429 / 502 / sandbox / EOF / connection abort) | 真 failed, provider 异常断开 | `/retry-other-provider <agent>` 切对家(claude → codex 或反向),走 handover 接续 |
| git 干净 + log 末尾完全卡住 N 分钟无新输出 | 真 hang(网络 / provider CLI 死) | 检查 watcher 进程 `bash agentctl.sh status` worker 列, 如 stale 重启 watcher;`/dispatch-<agent>` 重派 |

**严禁**:
- ❌ 看到 timeout 不查 hook 注入诊断, 直接重派 — 如果 work 已落, 重派会让对方重做(浪费 token)
- ❌ 主 Claude 自己改业务码"代劳" — 仍走 04 修复 → 派编码 agent 流程(由 settings.json deny 强制)

**关联自动恢复**: `_common.sh` `default_evaluate_completion` 在 timeout 时已自动检测 work-landed → 改判 stale, 信号自动转为 done-awaiting-review(memory bugs.md #25/#26/#29 SOP 内化)。所以"git 有改动"的 timeout 在 v3.0.4+ 通常**不会再触发** state=timeout, 而是直接 state=done-awaiting-review。仅 adapter 漏判的边缘情况才进本 SOP。

## ⛔ 切换编码 agent 接续流程 (Handover 机制)

**触发场景**: 编码 agent failed,且失败原因属"换家可能解决"类(API 限流 / token 配额 / sandbox 异常 / 网络抖动)。

**步骤**(主 Claude 必走):

1. 看 `events.jsonl` 末尾确认失败原因 (read,不依赖 message 关键词)
2. 决定是否值得换家:
   - ✅ 值得: rate-limit / quota / sandbox 错(provider 内禀问题)
   - ❌ 不值得: spec 错 / 业务码 bug / 测试 fail(换家也跑不通,该走 04 修复)
3. 调 `/retry-other-provider <agent>` 生成 handover.md 骨架
4. **fill 验收清单**(硬要求): 跑 spec § 自检 grep 矩阵,每条验收点填 ✅/❌
   - 不能跳过;不填直接派 → 编码 agent 没接续依据可能重做
   - ✅ 项给具体证据(`file.py:42 已实现`)
   - ❌ 项说明"还差什么"(`tests/test_x.py 第 N 行 assert 仍 NotImplementedError`)
5. 调 `/dispatch-<agent> --provider <other>` 派对家
6. 等编码 agent 完成 → 走标准 review + verify gate
7. 派单成功 → handover.md 自动归档到 `runtime/archive/`

**反例**(严禁):

- ❌ 看到 failed 直接 retry 同一 provider — 失败原因没解,徒劳
- ❌ 看到 failed 直接 dispatch 对家 (跳 retry-other-provider) — 没 handover,新 provider 不知接续可能重做
- ❌ retry-other-provider 后没填 ✅/❌ 直接 dispatch — 新 provider 看到空 ✅/❌ 段会重做

## 代码审查 Rubric — Karpathy 6 项

审查编码 agent 交付物时**必须**逐项走完。未过项直接判失败。

### A. 执行验证 (防"假装干活")
- [ ] 读 `.aiagents/logs/{be|fe}_<date>.log`,确认 编码 agent 真的执行了且有 diff 输出
- [ ] 读 `.aiagents/state/events.jsonl` 末尾 30 条,确认有 `running → done` 事件链
- [ ] 对受影响目录执行 `git status` / `git diff`,确认文件真的改了
- [ ] 如果 log 声称"完成"但 diff 为空或不相关 → 失败

### B. Think Before Coding (理解对了吗)
*Karpathy 原文*: "Don't assume. Don't hide confusion. Surface tradeoffs."
- [ ] 对照 02/03 指引,编码 agent 是按需求做还是做歪了
- [ ] 边界条件、异常路径、空值、并发是否考虑
- [ ] 有没有隐藏的假设没告诉用户
- [ ] 与 `.aiagents/memory/global/bugs.md` 里历史坑做交叉对比,有没有重蹈覆辙

### C. Simplicity First (有没有过度工程)
*Karpathy 原文*: "Minimum code that solves the problem. Nothing speculative."
- [ ] 新增的抽象、接口、设计模式是否必要
- [ ] 200 行能缩到 50 行吗
- [ ] 有没有"为未来扩展"的 speculative feature(YAGNI)

### D. Surgical Changes (有没有改到无关的地方)
*Karpathy 原文*: "Touch only what you must. Clean up only your own mess."
- [ ] Diff 里有没有无关的格式化、重命名、顺手重构
- [ ] 每一行改动能否追溯到 02/03 里的某条要求
- [ ] 有没有偷偷改配置、依赖、lint 规则

### E. Goal-Driven Execution (可验证吗)
*Karpathy 原文*: "Define success criteria. Loop until verified."
- [ ] 02/03 里每个验收点,是否有代码或测试支撑
- [ ] **实际跑一次** `BACKEND_TEST_CMD` 或 `FRONTEND_TEST_CMD`(从 `.aiagents/config.json` 或 `.claude/agents.conf` 读),把最后 20 行输出粘到 review 里。**光看文件内容不算验收**
- [ ] 前端没有独立测试时,最低要求 `cd <FRONTEND_DIR> && npm install --silent && npx vite build`(或等价 build 命令),要求 exit code = 0
- [ ] 后端没有独立测试时,最低要求 `python -c "import <module>"` 或 `./mvnw compile` 能过
- [ ] Lint 必须干净

> **⚠️ Windows Bash 编码约定(必须遵守)**:在 Bash 工具里运行 Python 命令时,**不能在 print() 里用 emoji**(如 `print('✅ OK')`)。Windows 终端默认 GBK/CP936 编码,无法编码 Unicode emoji,会抛 `UnicodeEncodeError: 'gbk' codec can't encode`。
> - ✅ 正确: `PYTHONUTF8=1 python -c "from main import app; print('import OK')"` 或 `python -c "from main import app; print('import OK')"`
> - ❌ 错误: `python -c "from main import app; print('✅ import OK')"`

> **⚠️ Bash CWD 约定**: 调用 `.aiagents/bin/agentctl.sh` 时,**必须用绝对路径**,因为审查过程中的 `cd` 命令会改变 bash 会话的工作目录:
> ```bash
> bash "$(git rev-parse --show-toplevel 2>/dev/null || pwd)/.aiagents/bin/agentctl.sh" status
> ```

### F. 框架一致性 sanity(附加,仅针对前端/后端常见错配)

快速扫一遍,任何不匹配 = 直接判失败并记到 04 修复单:

**前端 Vite + React**:
- [ ] `package.json` 的 `devDependencies` 里有 `@vitejs/plugin-react` 吗?
- [ ] `vite.config.*` 里有 `import react from '@vitejs/plugin-react'` 且 `plugins: [react()]` 吗?
- [ ] 入口 HTML 的 `<script src>` 指向的文件扩展名与实际文件一致(`main.jsx` vs `main.tsx`)
- [ ] 如用 TypeScript: `tsconfig.json` 存在,且 `jsx: "react-jsx"` 或对应值

**前端 Vite + Vue**:
- [ ] `@vitejs/plugin-vue` 安装并在 vite.config 里启用
- [ ] `.vue` SFC 文件用 `<script setup>` 或明确导出 setup 函数

**后端 FastAPI**:
- [ ] `requirements.txt` 包含 `fastapi` 和 ASGI server(`uvicorn[standard]` 或 `hypercorn`)
- [ ] 如果启用 CORS,`CORSMiddleware` 的 origins 与前端开发端口匹配

**后端 Spring Boot**:
- [ ] `pom.xml` 或 `build.gradle` 主模块包含 `spring-boot-starter-web`(REST)或 `-webflux`
- [ ] 有 `@SpringBootApplication` 主类

**任一栈的通用检查**:
- [ ] CORS/代理配置与前后端端口一致
- [ ] 不要前后端重复写同一个跨域方案

## Memory 使用规范

ai-agents-kit v2 引入了**三层 memory** 作为跨会话/跨项目的"长期记忆":

```
.aiagents/memory/
├── global/
│   ├── patterns.md      # 跨项目"做对了"的成功模式
│   └── bugs.md          # 跨项目踩过的坑(防止重复犯错)
├── projects/
│   └── context.md       # 本项目独有的决策、约束、术语
└── ideas/
    └── product-ideas.md # 产品想法库(跨项目复用)
```

**读取**(必做):
- 每次启动新会话:四份全读一遍
- 每次开始新需求或新阶段:扫一眼相关条目
- 在审查 B 项(Think)时:对照 bugs.md 做交叉验证

**写入**(三种触发):
1. 用户**显式**说"记一下 / 这个要记忆"→ 用 `/memory "<经验>"` 命令
2. **每个完整需求结束后**(联调通过)→ `/retrospective` 自动整理本轮经验,回写到对应文件
3. 审查中遇到**未在 bugs.md 里出现过的新坑**→ 直接编辑 `.aiagents/memory/global/bugs.md` 追加段落

**写入原则**:
- 单条经验要具体可复用(差例:"代码要简洁";好例:"Spring Boot 列表接口统一用 `Page<T>` 返回")
- 失败模式必写"现象 / 原因 / 教训"三段
- 不要写超过 6 个月一定过时的临时性事项

## 审查报告格式

每一轮审查追加一段到 `docs/ai-agents/reviews/backend-review.md` 或 `frontend-review.md`,格式:

```markdown
## 第 N 轮 · <backend|frontend> · <YYYY-MM-DD HH:MM>

**触发源**: Stop hook (state: done-awaiting-review @ <state.updated_at>) / 用户 `/review`
**审查时机确认**: ✅ state.<agent>.state == done-awaiting-review;events.jsonl 末尾有 done 事件 @ <time>

**执行验证**: ✅ / ❌(写原因)
**Think Before Coding**: ✅ / ❌
**Simplicity First**: ✅ / ❌
**Surgical Changes**: ✅ / ❌
**Goal-Driven Execution**: ✅ / ❌
  - 跑了什么命令: `...`
  - exit code: 0
  - 输出尾 10 行:
    ```
    ...
    ```
**框架一致性 sanity**: ✅ / ❌(列出检查项)

**失败项**(按原则分类):
- [D/Surgical] `apps/api/UserService.java:45` — 无关重构: ...
- [E/Goal] 测试 `UserServiceTest#shouldReturn404` 未覆盖 02 第 3 条要求
- [F/Sanity] `package.json` 缺 `@vitejs/plugin-react`,`npm run dev` 会报 JSX 解析失败

**结论**: 通过 ✅ / 需修复 ❌

**修复指令**(若需修复 → 写到 `docs/ai-agents/specs/04-Bug修复-<layer>.md`):
1. 在 `<前端目录>/package.json` 的 devDependencies 里加 `"@vitejs/plugin-react": "^4.3.0"`
2. 在 `vite.config.js` 的 plugins 数组里加 `react()`
3. 再跑一遍 `npm install && npx vite build` 证明能过
```

## 项目上下文占位

用户在 `install.sh` / `install.ps1` 里会把以下占位替换成真实值,你首次使用时先读这一段:

- **后端技术栈**: `<BACKEND_STACK>` (轻量首选 `FastAPI + SQLAlchemy`;重型如 `Spring Boot 3.x + JPA + PostgreSQL`)
- **前端技术栈**: `<FRONTEND_STACK>` (常用 `Vite + React`,或 `Next.js` / `Vite + Vue`)
- **后端测试命令**: `<BACKEND_TEST_CMD>` (Python: `pytest` / Java: `./mvnw test` / Go: `go test ./...`)
- **前端测试命令**: `<FRONTEND_TEST_CMD>` (通常 `npm test` / `npx vitest run`)
- **后端 lint 命令**: `<BACKEND_LINT_CMD>` (Python: `ruff check .` / Java: `./mvnw spotless:check`)
- **前端 lint 命令**: `<FRONTEND_LINT_CMD>` (通常 `npm run lint`)
- **现有 API 契约位置**: `<API_CONTRACT_PATH>` (如 `docs/openapi.yaml`,没有就留空)

## 防误用约束

- 不要在未经用户确认的情况下自动进入下一阶段
- 不要自己写业务代码,只产出编码指引和审查报告
- 不要改 `.aiagents/bin/` 里的脚本(它们是基础设施)
- 不要手动 `touch` `.aiagents/signals/` 下的文件(用 slash command 或 `agentctl.sh dispatch`)
- 每轮审查追加不覆盖,保留完整审查历史
- **状态判断只看 `state/current.json` 的 `<agent>.state` 字段**,不要凭日志、events.jsonl、文件存在性推测

> <!-- ai-agents-kit:end v2 -->

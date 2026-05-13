#!/usr/bin/env python
"""Stream filter: claude --output-format stream-json --verbose → human-readable text.

stdin: JSON Lines (claude stream-json) interleaved with possibly non-JSON lines (banners, errors).
stdout: 默认 minimal 模式 — 只输出动作信号(🔧 工具调用 / 🟢 init / ✅ result / ❌ tool error)。

设 STREAM_VERBOSE=1 解锁详细模式 — 加 💬 思考文本 + ✓ tool_result(成功)+ 🤔 thinking 块。

Non-JSON lines pass through unchanged (容错 — banner / runtime error / etc 不丢).
Unknown JSON event types pass through as raw JSON (debug-friendly).

设计意图: Lane 关心"claude 在动还是 hang",不关心 old_string/new_string/CoT 思考。
默认极简,需要 debug 时开 verbose。

2026-05-13 升级(Lane 要求):
  - Bash 显示前 60 字符 + 跳 env 前缀(VAR=val cmd → cmd)
  - Read 同文件连续读折叠为 [+N]
  - Edit 显示 old_string 前 30 字
  - 每行加 [HH:MM:SS] 时间戳
  - 错误 300 字符 + ━━━ 分割线
  - 3+ 连续 pwd/ls/cd 折叠为 🔍 env probe ×N
  - init/result 加 ═ 分割线

Used by claude.sh provider_build_cmd. Codex provider doesn't use this (走 filter-output.sh awk).
"""
import sys, json, os, re, datetime

VERBOSE = os.environ.get('STREAM_VERBOSE') in ('1', 'true', 'yes')

# Force UTF-8 stdin/stdout/stderr regardless of Windows terminal codec.
try:
    sys.stdin.reconfigure(encoding='utf-8', errors='replace')
    sys.stdout.reconfigure(encoding='utf-8', line_buffering=True)
    sys.stderr.reconfigure(encoding='utf-8')
except Exception:
    pass


# ───────── state for cross-line dedup/coalesce ─────────
STATE = {
    'last_read_path': None,   # 最近一次 Read 的 file_path
    'read_repeat': 0,          # 连续读同一文件的次数(不含首次)
    'probe_streak': 0,         # 连续 pwd/ls/cd 等探索命令计数
}

PROBE_COMMANDS = {
    'pwd', 'ls', 'cd', 'cat', 'find', 'which', 'whoami', 'echo',
    'date', 'env', 'printenv', 'head', 'tail', 'wc',
}
ENV_PREFIX_RE = re.compile(r'^[A-Z_][A-Z0-9_]*=')
SEP_HEAVY = '═' * 60
SEP_LIGHT = '━' * 60


def _ts():
    return datetime.datetime.now().strftime('%H:%M:%S')


def _strip_env_prefix(cmd):
    """Strip leading VAR=value VAR=value ... env prefixes from a bash command.
    `PYTHONUTF8=1 alembic upgrade head` → `alembic upgrade head`
    """
    parts = cmd.split()
    i = 0
    while i < len(parts) and ENV_PREFIX_RE.match(parts[i]):
        i += 1
    return ' '.join(parts[i:]) if i < len(parts) else cmd


def _truncate(s, n):
    s = s.replace('\n', ' ⏎ ')
    return s if len(s) <= n else s[:n-3] + '...'


def _bash_brief(cmd):
    cmd = _strip_env_prefix((cmd or '').strip())
    return _truncate(cmd, 60) if cmd else ''


def _tool_brief(name, inp):
    """Return short target hint for a tool_use, or '' if no useful brief."""
    if not isinstance(inp, dict):
        return _truncate(str(inp), 80)
    if name == 'Bash':
        return _bash_brief(inp.get('command', ''))
    if name in ('Edit', 'MultiEdit', 'NotebookEdit'):
        fname = os.path.basename(str(inp.get('file_path', '?'))) or '?'
        old = str(inp.get('old_string', ''))
        if old:
            return f"{fname} '{_truncate(old, 30)}'"
        return fname
    if name == 'Write':
        fname = os.path.basename(str(inp.get('file_path', '?'))) or '?'
        content = inp.get('content', '')
        size = f"{len(content)}c" if content else ''
        return f"{fname} ({size})" if size else fname
    if 'file_path' in inp:
        return os.path.basename(str(inp['file_path']))
    if 'pattern' in inp:
        return f"`{_truncate(str(inp['pattern']), 40)}`"
    if 'description' in inp:
        return _truncate(str(inp['description']), 50)
    if 'url' in inp:
        return _truncate(str(inp['url']), 60)
    if 'query' in inp:
        return f"q={_truncate(str(inp['query']), 40)}"
    return ''


def _is_probe(name, inp):
    """探索性 / 只读 Bash 命令(pwd/ls/cd 等),用于 3+ 连续折叠。
    Read tool 不算 probe(单独折叠逻辑)。"""
    if name != 'Bash':
        return False
    if not isinstance(inp, dict):
        return False
    cmd = _strip_env_prefix((inp.get('command') or '').strip())
    first = cmd.split(None, 1)[0] if cmd else ''
    return first in PROBE_COMMANDS


def _flush_probe_streak(out):
    """已显示前 2 个 probe;streak ≥ 3 时,emit `(+N env probes hidden)` 表示折叠数量。"""
    folded = STATE['probe_streak'] - 2
    if folded > 0:
        out.append(f"[{_ts()}] 🔍 (+{folded} env probes hidden)")
    STATE['probe_streak'] = 0


def fmt(d):
    """Return list[str] of formatted lines for one parsed JSON object, or None to fall through."""
    t = d.get('type')
    out = []
    if t == 'system':
        sub = d.get('subtype', '')
        if sub == 'init':
            _flush_probe_streak(out)
            STATE['last_read_path'] = None
            STATE['read_repeat'] = 0
            sid = (d.get('session_id') or '?')[:8]
            tools = d.get('tools') or []
            out.append(SEP_HEAVY)
            out.append(f"[{_ts()}] 🟢 [init] session={sid} tools={len(tools)}")
            out.append(SEP_HEAVY)
        elif VERBOSE:
            out.append(f"[{_ts()}] 🟢 [system/{sub}]")
    elif t == 'assistant':
        msg = d.get('message') or {}
        for c in msg.get('content') or []:
            ct = c.get('type')
            if ct == 'text':
                if VERBOSE:
                    txt = (c.get('text') or '').rstrip()
                    if txt:
                        _flush_probe_streak(out)
                        out.append(f"[{_ts()}] 💬 {txt}")
            elif ct == 'tool_use':
                name = c.get('name', '?')
                inp = c.get('input') or {}

                # ── 1. Read 同文件折叠 ──
                if name == 'Read':
                    path = str(inp.get('file_path', '')) if isinstance(inp, dict) else ''
                    fname = os.path.basename(path) if path else ''
                    if path and path == STATE['last_read_path']:
                        STATE['read_repeat'] += 1
                        # 第 2/3/4... 次读同文件:不新增行,但极简标记
                        out.append(f"[{_ts()}] 🔧 Read {fname} [+{STATE['read_repeat']}]")
                    else:
                        _flush_probe_streak(out)
                        STATE['last_read_path'] = path
                        STATE['read_repeat'] = 0
                        out.append(f"[{_ts()}] 🔧 Read {fname or '?'}")
                    continue

                # ── 2. Bash probe 折叠(pwd/ls/cd 连续 3+ 静默,flush 时报总数) ──
                if _is_probe(name, inp):
                    STATE['last_read_path'] = None
                    STATE['probe_streak'] += 1
                    if STATE['probe_streak'] <= 2:
                        # 前 2 个仍单独显示
                        brief = _tool_brief(name, inp)
                        out.append(f"[{_ts()}] 🔧 {name} {brief}" if brief else f"[{_ts()}] 🔧 {name}")
                    # streak >= 3:完全静默,_flush_probe_streak 在 streak 结束时 emit `🔍 env probe ×N`
                    continue

                # ── 3. 其他工具(Edit / Write / Grep / Glob / 非 probe 的 Bash 等) ──
                _flush_probe_streak(out)
                STATE['last_read_path'] = None
                brief = _tool_brief(name, inp)
                if brief:
                    out.append(f"[{_ts()}] 🔧 {name} {brief}")
                else:
                    out.append(f"[{_ts()}] 🔧 {name}")
            elif ct == 'thinking':
                if VERBOSE:
                    txt = (c.get('thinking') or '').rstrip()
                    if txt:
                        _flush_probe_streak(out)
                        out.append(f"[{_ts()}] 🤔 {_truncate(txt, 200)}")
    elif t == 'user':
        msg = d.get('message') or {}
        for c in msg.get('content') or []:
            if c.get('type') == 'tool_result':
                err = c.get('is_error') or False
                if err:
                    _flush_probe_streak(out)
                    content = c.get('content', '')
                    if isinstance(content, list):
                        content = ''.join(
                            x.get('text', str(x)) if isinstance(x, dict) else str(x)
                            for x in content
                        )
                    snippet = _truncate(str(content), 300)
                    out.append(SEP_LIGHT)
                    out.append(f"[{_ts()}] ❌ tool error")
                    out.append(f"        {snippet}")
                    out.append(SEP_LIGHT)
                elif VERBOSE:
                    content = c.get('content', '')
                    if isinstance(content, list):
                        content = ''.join(
                            x.get('text', str(x)) if isinstance(x, dict) else str(x)
                            for x in content
                        )
                    snippet = _truncate(str(content), 100)
                    out.append(f"[{_ts()}] ✓ tool_result {snippet}")
    elif t == 'result':
        _flush_probe_streak(out)
        STATE['last_read_path'] = None
        cost = d.get('total_cost_usd', '?')
        turns = d.get('num_turns', '?')
        is_err = d.get('is_error') or False
        sub = d.get('subtype', '')
        emoji = '❌' if is_err else '✅'
        suf = " · ERROR" if is_err else ""
        if sub:
            suf += f" · {sub}"
        out.append(SEP_HEAVY)
        out.append(f"[{_ts()}] {emoji} result · cost=${cost} · turns={turns}{suf}")
        out.append(SEP_HEAVY)
    else:
        return None  # fall through (raw JSON)
    return out


for line in sys.stdin:
    line = line.rstrip('\n')
    if not line:
        print('', flush=True)
        continue
    try:
        d = json.loads(line)
    except Exception:
        # Non-JSON: pass through but reset state
        _flush_buf = []
        _flush_probe_streak(_flush_buf)
        for ln in _flush_buf:
            print(ln, flush=True)
        STATE['last_read_path'] = None
        print(line, flush=True)
        continue
    formatted = fmt(d)
    if formatted is None:
        print(line, flush=True)
    else:
        for ln in formatted:
            print(ln, flush=True)

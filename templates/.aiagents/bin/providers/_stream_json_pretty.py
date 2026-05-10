#!/usr/bin/env python
"""Stream filter: claude --output-format stream-json --verbose → human-readable text.

stdin: JSON Lines (claude stream-json) interleaved with possibly non-JSON lines (banners, errors).
stdout: 默认 minimal 模式 — 只输出动作信号(🔧 工具调用 / 🟢 init / ✅ result / ❌ tool error)。

设 STREAM_VERBOSE=1 解锁详细模式 — 加 💬 思考文本 + ✓ tool_result(成功)+ 🤔 thinking 块。

Non-JSON lines pass through unchanged (容错 — banner / runtime error / etc 不丢).
Unknown JSON event types pass through as raw JSON (debug-friendly).

设计意图: Lane 关心"claude 在动还是 hang",不关心 old_string/new_string/CoT 思考。
默认极简,需要 debug 时开 verbose。

Used by claude.sh provider_build_cmd. Codex provider doesn't use this (走 filter-output.sh awk).
"""
import sys, json, os

VERBOSE = os.environ.get('STREAM_VERBOSE') in ('1', 'true', 'yes')

# Force UTF-8 stdin/stdout/stderr regardless of Windows terminal codec (emoji-safe + CJK-safe).
# Python 3.7+ supports reconfigure; runner also exports PYTHONUTF8=1 / PYTHONIOENCODING=utf-8 as belt-and-suspenders.
try:
    sys.stdin.reconfigure(encoding='utf-8', errors='replace')
    sys.stdout.reconfigure(encoding='utf-8', line_buffering=True)
    sys.stderr.reconfigure(encoding='utf-8')
except Exception:
    pass

def _tool_brief(name, inp):
    """Return short target hint for a tool_use, or '' if no useful brief."""
    if not isinstance(inp, dict):
        return str(inp)[:80]
    # Prefer specific keys for known tools
    if 'file_path' in inp:
        # Show only basename for brevity
        path = str(inp['file_path'])
        return path.rsplit('/', 1)[-1].rsplit('\\', 1)[-1]
    if 'command' in inp:
        # First "word" of the command (e.g. "pytest" / "git" / "npm")
        cmd = str(inp['command']).strip()
        return cmd.split(None, 1)[0] if cmd else ''
    if 'pattern' in inp:
        return f"`{str(inp['pattern'])[:40]}`"
    if 'description' in inp:
        return str(inp['description'])[:50]
    if 'url' in inp:
        return str(inp['url'])[:60]
    if 'query' in inp:
        return f"q={str(inp['query'])[:40]}"
    return ''


def fmt(d):
    """Return list[str] of formatted lines for one parsed JSON object, or None to fall through."""
    t = d.get('type')
    out = []
    if t == 'system':
        sub = d.get('subtype', '')
        if sub == 'init':
            sid = (d.get('session_id') or '?')[:8]
            tools = d.get('tools') or []
            out.append(f"🟢 [init] session={sid} tools={len(tools)}")
        elif VERBOSE:
            out.append(f"🟢 [system/{sub}]")
    elif t == 'assistant':
        msg = d.get('message') or {}
        for c in msg.get('content') or []:
            ct = c.get('type')
            if ct == 'text':
                # Default minimal: silent (CoT 噪音多)
                # Verbose: show full text
                if VERBOSE:
                    txt = (c.get('text') or '').rstrip()
                    if txt:
                        out.append(f"💬 {txt}")
            elif ct == 'tool_use':
                name = c.get('name', '?')
                inp = c.get('input') or {}
                brief = _tool_brief(name, inp)
                if brief:
                    out.append(f"🔧 {name} {brief}")
                else:
                    out.append(f"🔧 {name}")
            elif ct == 'thinking':
                # Default minimal: 不输出 thinking (claude 内部 CoT 与 Lane 无关)
                # Verbose: 显示前 200 字
                if VERBOSE:
                    txt = (c.get('thinking') or '').rstrip()
                    if txt:
                        out.append(f"🤔 {txt[:200]}{'...' if len(txt) > 200 else ''}")
    elif t == 'user':
        msg = d.get('message') or {}
        for c in msg.get('content') or []:
            if c.get('type') == 'tool_result':
                err = c.get('is_error') or False
                # Default minimal: 只显示 error, 成功 result 静默
                # Verbose: 显示成功 result 内容前 100 字
                if err:
                    content = c.get('content', '')
                    if isinstance(content, list):
                        content = ''.join(
                            x.get('text', str(x)) if isinstance(x, dict) else str(x)
                            for x in content
                        )
                    snippet = str(content)[:100].replace('\n', ' ⏎ ')
                    out.append(f"❌ tool error: {snippet}")
                elif VERBOSE:
                    content = c.get('content', '')
                    if isinstance(content, list):
                        content = ''.join(
                            x.get('text', str(x)) if isinstance(x, dict) else str(x)
                            for x in content
                        )
                    snippet = str(content)[:100].replace('\n', ' ⏎ ')
                    out.append(f"✓ tool_result {snippet}{'...' if len(str(content)) > 100 else ''}")
    elif t == 'result':
        cost = d.get('total_cost_usd', '?')
        turns = d.get('num_turns', '?')
        is_err = d.get('is_error') or False
        sub = d.get('subtype', '')
        suf = " · ERROR" if is_err else ""
        if sub:
            suf += f" · {sub}"
        out.append(f"✅ result · cost=${cost} · turns={turns}{suf}")
    else:
        return None  # fall through (raw JSON)
    return out

for line in sys.stdin:
    line = line.rstrip('\n')
    if not line:
        print('', flush=True)
        continue
    # Try parse as JSON
    try:
        d = json.loads(line)
    except Exception:
        # Not JSON — pass through (e.g. banner / runtime error / shell echo)
        print(line, flush=True)
        continue
    formatted = fmt(d)
    if formatted is None:
        # Unknown event type — pass through raw JSON (debug-friendly)
        print(line, flush=True)
    else:
        for ln in formatted:
            print(ln, flush=True)

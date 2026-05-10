#!/usr/bin/env python
"""Stream filter: claude --output-format stream-json --verbose → human-readable text.

stdin: JSON Lines (claude stream-json) interleaved with possibly non-JSON lines (banners, errors).
stdout: friendly one-line-per-event format ("💬 ..." / "🔧 Tool ..." / "✅ result ...").

Non-JSON lines pass through unchanged (容错 — banner / runtime error / etc 不丢).
Unknown JSON event types pass through as raw JSON (debug-friendly).

Used by claude.sh provider_build_cmd to render claude subprocess stdout to log.
Codex provider doesn't use this (codex emits human text already, processed by filter-output.sh).
"""
import sys, json

# Force UTF-8 stdin/stdout/stderr regardless of Windows terminal codec (emoji-safe + CJK-safe).
# Python 3.7+ supports reconfigure; runner also exports PYTHONUTF8=1 / PYTHONIOENCODING=utf-8 as belt-and-suspenders.
try:
    sys.stdin.reconfigure(encoding='utf-8', errors='replace')
    sys.stdout.reconfigure(encoding='utf-8', line_buffering=True)
    sys.stderr.reconfigure(encoding='utf-8')
except Exception:
    pass

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
        else:
            out.append(f"🟢 [system/{sub}]")
    elif t == 'assistant':
        msg = d.get('message') or {}
        for c in msg.get('content') or []:
            ct = c.get('type')
            if ct == 'text':
                txt = (c.get('text') or '').rstrip()
                if txt:
                    out.append(f"💬 {txt}")
            elif ct == 'tool_use':
                name = c.get('name', '?')
                inp = c.get('input') or {}
                # Compact preview of tool input (truncated)
                if isinstance(inp, dict):
                    keys = list(inp.keys())
                    if 'file_path' in inp:
                        snippet = str(inp['file_path'])
                    elif 'command' in inp:
                        snippet = str(inp['command'])[:140]
                    elif 'pattern' in inp:
                        snippet = f"pattern={inp['pattern']!r}"
                    else:
                        snippet = ' '.join(f"{k}={str(inp[k])[:40]}" for k in keys[:3])
                else:
                    snippet = str(inp)[:140]
                out.append(f"🔧 {name} {snippet}")
            elif ct == 'thinking':
                txt = (c.get('thinking') or '').rstrip()
                if txt:
                    # Show first 200 chars of thinking
                    out.append(f"🤔 {txt[:200]}{'...' if len(txt) > 200 else ''}")
    elif t == 'user':
        msg = d.get('message') or {}
        for c in msg.get('content') or []:
            if c.get('type') == 'tool_result':
                err = c.get('is_error') or False
                content = c.get('content', '')
                if isinstance(content, list):
                    content = ''.join(
                        x.get('text', str(x)) if isinstance(x, dict) else str(x)
                        for x in content
                    )
                snippet = str(content)[:100].replace('\n', ' ⏎ ')
                marker = "❌ tool_result" if err else "✓ tool_result"
                out.append(f"{marker} {snippet}{'...' if len(str(content)) > 100 else ''}")
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

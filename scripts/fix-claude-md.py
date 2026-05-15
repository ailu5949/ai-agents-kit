#!/usr/bin/env python3
"""修复被 install CLAUDE.md 重复标题 bug (v3.4.4 之前) 搞坏的项目 CLAUDE.md。

背景: v3.4.4 之前的 install.sh / install.ps1 有个 bug — rendered 含 marker
之前的标题块, 每跑一次 install 就在 marker 前面多插一个 "# 三 Agent..." 标题。
还可能导致 start marker 丢失。

用法:
    cd <你的项目根>          # 含 CLAUDE.md 的目录
    python /path/to/ai-agents-kit/scripts/fix-claude-md.py

作用:
    - 删掉重复的 "# 三 Agent 协作工作流" 标题块, 只留 1 个
    - 补回缺失的 <!-- ai-agents-kit:start v2 --> marker
    - 保留 end marker 之后的用户项目专属内容 (如 "# 项目特化规则")
    - 原文件备份到 CLAUDE.md.broken.bak

幂等: 已经正常的 CLAUDE.md 跑一遍结果不变。
修复后再跑一次 v3.4.4+ install 即可把 kit 正文同步到最新。
"""
import sys
import pathlib

HEADER = (
    "# 三 Agent 协作工作流 — 项目级指令\n"
    "\n"
    "> 本节由 **ai-agents-kit** 安装,请勿手动编辑开头的 5 行 marker。"
    "如要升级请重跑 `install.sh` 或 `install.ps1`。\n"
    "> <!-- ai-agents-kit:start v2 -->"
)
TITLE_LINE = "# 三 Agent 协作工作流 — 项目级指令"

def main():
    p = pathlib.Path("CLAUDE.md")
    if not p.exists():
        print("当前目录没有 CLAUDE.md — 请 cd 到项目根再跑")
        return 1

    text = p.read_text(encoding="utf-8")
    lines = text.split("\n")

    # 找 end marker 行
    end_idx = None
    for i, line in enumerate(lines):
        if "ai-agents-kit:end v2" in line:
            end_idx = i
            break
    if end_idx is None:
        print("没找到 <!-- ai-agents-kit:end v2 --> marker")
        print("→ 这个 CLAUDE.md 可能不是 ai-agents-kit 装的, 或损坏太严重, 不自动改")
        return 1

    # 找 kit 正文起点: 第一个 "## " 开头的行 (templates 里是 "## 新会话...")
    body_start = None
    for i, line in enumerate(lines):
        if line.startswith("## "):
            body_start = i
            break
    if body_start is None or body_start >= end_idx:
        print("没找到 kit 正文 (## 开头的行), 不自动改")
        return 1

    # 统计修复前重复标题数
    dup_titles = sum(
        1 for line in lines[:body_start] if line.strip() == TITLE_LINE
    )

    kit_body = "\n".join(lines[body_start:end_idx]).rstrip("\n")
    user_tail = "\n".join(lines[end_idx + 1:])

    # 重组: 标准 header + kit 正文 + end marker + 用户尾部
    new = HEADER + "\n\n" + kit_body + "\n> <!-- ai-agents-kit:end v2 -->\n"
    if user_tail.strip():
        new += user_tail if user_tail.startswith("\n") else "\n" + user_tail
    if not new.endswith("\n"):
        new += "\n"

    if new == text:
        print("CLAUDE.md 结构已正常, 无需修复")
        return 0

    # 备份 + 写回
    bak = pathlib.Path("CLAUDE.md.broken.bak")
    bak.write_text(text, encoding="utf-8")
    p.write_text(new, encoding="utf-8")

    tail_lines = len([x for x in user_tail.split("\n") if x]) if user_tail.strip() else 0
    print("修复完成:")
    print(f"  重复标题块: {dup_titles} → 1")
    print(f"  start marker: 已补回")
    print(f"  end marker 之后用户内容: {'保留 ' + str(tail_lines) + ' 行' if tail_lines else '无'}")
    print(f"  原文件备份: {bak.name}")
    print()
    print("下一步: 重跑 v3.4.4+ 的 install.sh 把 kit 正文同步到最新")
    return 0

if __name__ == "__main__":
    sys.exit(main())

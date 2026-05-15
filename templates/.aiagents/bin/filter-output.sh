#!/usr/bin/env bash
# 过滤编码 agent 输出: 保留进度摘要,去掉 diff 具体内容。
# 完整输出仍然写入 log,这个脚本只用于终端显示。
#
# 保留: codex 思考行、exec 命令(截断)、文件写入摘要、succeeded/declined/rejected、
#        tokens used、✅/❌ 结果行
# 去掉: diff --git / index / --- / +++ / @@ / 以及 diff hunk 内的 +/-/空格行

awk '
  # ── diff 块: 只记文件名,不打印内容 ──
  /^diff --git/        { in_diff=1; diff_files=diff_files "," $3; next }
  in_diff && /^index / { next }
  in_diff && /^---/    { next }
  in_diff && /^\+\+\+/ { next }
  in_diff && /^@@/     { next }
  in_diff && /^[ +-]/  { next }
  in_diff {
    in_diff=0
    n = split(diff_files, arr, ",")
    f1=""; f2=""
    for (i=1; i<=n; i++) {
      if (arr[i] != "" && f1 == "") f1 = arr[i]
      else if (arr[i] != "" && arr[i] != f1 && f2 == "") f2 = arr[i]
    }
    if (f2 != "") printf "  📝 写入: %s, %s\n", f1, f2
    else if (f1 != "") printf "  📝 写入: %s\n", f1
    diff_files=""
    print
  }
  in_diff { next }

  # ── exec 命令: 缩短显示 ──
  /^exec/ {
    line = $0
    sub(/^exec[[:space:]]*/, "", line)
    if (length(line) > 120) line = substr(line, 1, 117) "..."
    printf "  🔧 执行: %s\n", line
    next
  }

  # ── 结果行: 保留 ──
  /succeeded in/       { printf "  ✅ %s\n", $0; next }
  /declined in/        { printf "  ⛔ %s\n", $0; next }
  /rejected/           { printf "  ❌ %s\n", $0; next }

  # ── codex 思考行: 保留(用户最关心的进度信号) ──
  /^codex/ {
    if (length($0) > 200) print substr($0, 1, 197) "..."
    else print
    next
  }

  # ── 补丁/文件操作提示 ──
  /apply patch/        { printf "  📦 生成代码中...\n"; next }
  /patch: completed/   { printf "  ✅ 代码已写入\n"; next }

  # ── 其他 ──
  { print }
'

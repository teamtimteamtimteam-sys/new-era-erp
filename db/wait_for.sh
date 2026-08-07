#!/bin/bash
# db/wait_for.sh — 有上限、会报名字的等待。
#
# 【为什么存在】2026-08-07 有一个壳等了 2 小时 47 分钟,等的是一个永远不会出现的
# 字符串:被等的那个进程早就死了,而
#     until grep -q "判词" gate.log; do sleep 5; done
# 这种写法【没有失败分支】—— 条件不成立它就继续等,安静地,直到有人发现。
# 同一形状此前已经发生过一次(等备份),当时的处置是"记住要加上限"。
# 记住没有用:第二次照样发生。所以改成机制 —— 这个脚本【不接受没有上限的等待】,
# --timeout 与 --label 都是必填,漏掉任何一个当场退出。
#
# 用法:
#     db/wait_for.sh --timeout 900 --label "db/gate.py 三判词" -- \
#         grep -q "判词【行为断言】" /tmp/gate.log
#
#     db/wait_for.sh --timeout 300 --label "备份 dump 落盘" --interval 10 -- \
#         test -s ~/evoltrya-backups/latest.dump
#
# --  之后的一切当作命令执行,退出码 0 视为条件成立。
# 退出码:0 = 条件成立 · 3 = 超时(会打印等的是什么、等了多久)· 2 = 用法错误
set -uo pipefail

TIMEOUT=""; LABEL=""; INTERVAL=5
while [ $# -gt 0 ]; do
    case "$1" in
        --timeout)  TIMEOUT="${2:-}"; shift 2 ;;
        --label)    LABEL="${2:-}";   shift 2 ;;
        --interval) INTERVAL="${2:-}"; shift 2 ;;
        --) shift; break ;;
        *) echo "✗ wait_for:认不得的参数 $1" >&2; exit 2 ;;
    esac
done

# 【必填,不给默认值】给 --timeout 一个默认值就等于把上限又变成了"可以不想",
# 而这个脚本存在的全部理由就是不许不想。
[ -n "$TIMEOUT" ] || { echo "✗ wait_for:必须给 --timeout <秒> —— 没有上限的等待正是本脚本要消灭的东西" >&2; exit 2; }
[ -n "$LABEL" ]   || { echo "✗ wait_for:必须给 --label <等的是什么> —— 超时时要说得出等的是谁" >&2; exit 2; }
[ $# -gt 0 ]      || { echo "✗ wait_for:-- 之后要给一条命令" >&2; exit 2; }
case "$TIMEOUT" in ''|*[!0-9]*) echo "✗ wait_for:--timeout 必须是整数秒" >&2; exit 2 ;; esac

START=$(date +%s)
LAST_TICK=$START
while true; do
    if "$@" >/dev/null 2>&1; then
        echo "✓ 等到了:$LABEL($(( $(date +%s) - START ))s)"
        exit 0
    fi
    NOW=$(date +%s); ELAPSED=$(( NOW - START ))
    if [ "$ELAPSED" -ge "$TIMEOUT" ]; then
        # 【超时必须说清楚三件事】等的是什么、等了多久、上限是多少。
        # 只打印 "timeout" 的等待,和没有上限的等待一样难查。
        echo "✗ 等待超时:$LABEL" >&2
        echo "   等了 ${ELAPSED}s,上限 ${TIMEOUT}s —— 条件始终没成立。" >&2
        echo "   条件:$*" >&2
        echo "   被等的那个东西多半已经死了或从未开始;去看它的日志,不要加大上限。" >&2
        exit 3
    fi
    # 每分钟吭一声:活着的等待和挂住的等待,在屏幕上不该长得一样
    if [ $(( NOW - LAST_TICK )) -ge 60 ]; then
        echo "   …仍在等 $LABEL(${ELAPSED}s / ${TIMEOUT}s)"
        LAST_TICK=$NOW
    fi
    sleep "$INTERVAL"
done

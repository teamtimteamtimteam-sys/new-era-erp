#!/bin/bash
# db/run_detached.sh —— 后台跑一支长脚本,而【判词只能来自脚本自己打出来的那一行】。
#
# ════════════════════════════════════════════════════════════════════════════
# 【为什么存在:同一个形状在一次会话里骗了五次】(EQP-2c,2026-08-21)
#
# AGENTS.md 已经把判据写清楚了 ——
#
#   > 备份跑完的唯一证据,是 backup.log 里那一行【脚本自己打出来的退出码】。
#   > 不是启动器的状态、不是通知、不是 pgrep、不是文件存在、不是 ls -t 最新的那个。
#
# 那句话是对的,而且写在正确的地方。**它没能拦住任何一次。** 同一次会话里
# 【启动器的退出码冒充了脚本的退出码】五次:备份一次,冒烟四次。每一次的画面
# 都一样 —— harness 报「completed (exit code 0)」,而脚本还在跑,日志里连总结行
# 都没有。EQP-1c-b-fu2 的提交信息把第四次记了下来,然后第五次照样发生。
#
# **一条要靠人记着的规矩,已经证明了它记不住。** 这个仓库对这件事有一条成文的
# 处置(OPS-7 用脚本替掉两句"记得检查 B1 与 is_system";db/wait_for.sh 替掉
# "记得给等待加上限"):**把注解换成机制。** 这支脚本就是那次替换。
#
# 【它做的三件事,每一件对着上面那句话的一半】
#   ① 把命令跑在一个子壳里,并让【那个子壳】把命令自己的退出码追加成
#      `<TOKEN>_EXIT=<n>` —— 于是日志里那一行的作者是被等的那支脚本,
#      不是启动它的东西;
#   ② 用 db/wait_for.sh 等那一行出现(有上限、有失败分支,不自己手写 until 循环);
#   ③ **拿不到那一行就【拒绝给判词】** —— 退出码 3,并明说"没有拿到脚本自己的
#      退出码,所以本脚本【不知道】它成没成功"。这一条是重点:一个说不出话的
#      检查必须说"我不知道",绝不能沉默着变绿。
#
# 【为什么是包装,而不是"以后都记得写那三行"】那三行(子壳 + wait_for + grep)
# 正是 AGENTS.md 已经写出来的样板,而它被跳过了五次。样板与机制的区别就是这个:
# 样板要人照抄,机制不照抄就跑不起来。
#
# 【它不解决什么,写下来免得被当成万能】它证明的只是"那支脚本跑完了,退出码是 n"。
# 脚本自己撒谎(BK-FIX 之前的 backup.sh:印着失败却退 0)不在它的射程内 ——
# 那一条的处置是修那支脚本,已经做过了。两条判据叠在一起才完整:
# **脚本要说真话(BK-FIX),而它说的话要真的被读到(本脚本)。**
# ════════════════════════════════════════════════════════════════════════════
#
# 用法:
#     db/run_detached.sh --log /tmp/backup.log --label "备份" --timeout 2400 \
#         -- ~/evoltrya-backups/backup.sh
#
# 退出码:被等脚本自己的退出码 · 3 = 超时/拿不到那一行(判词【未知】) · 2 = 用法错误
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG=""; LABEL=""; TIMEOUT=""; TOKEN="RUN"; INTERVAL=10
while [ $# -gt 0 ]; do
    case "$1" in
        --log)      LOG="${2:-}";      shift 2 ;;
        --label)    LABEL="${2:-}";    shift 2 ;;
        --timeout)  TIMEOUT="${2:-}";  shift 2 ;;
        --token)    TOKEN="${2:-}";    shift 2 ;;
        --interval) INTERVAL="${2:-}"; shift 2 ;;
        --) shift; break ;;
        *) echo "✗ run_detached:认不得的参数 $1" >&2; exit 2 ;;
    esac
done
# 【三个都必填,一个默认值都不给】理由与 wait_for.sh 逐字相同:给了默认值,
# 上限就又变成了"可以不想",而不想正是这支脚本要消灭的东西。
[ -n "$LOG" ]     || { echo "✗ run_detached:必须给 --log <日志路径>" >&2; exit 2; }
[ -n "$LABEL" ]   || { echo "✗ run_detached:必须给 --label <等的是什么>" >&2; exit 2; }
[ -n "$TIMEOUT" ] || { echo "✗ run_detached:必须给 --timeout <秒>" >&2; exit 2; }
[ $# -gt 0 ]      || { echo "✗ run_detached:-- 之后要给一条命令" >&2; exit 2; }
case "$TIMEOUT" in ''|*[!0-9]*) echo "✗ run_detached:--timeout 必须是整数秒" >&2; exit 2 ;; esac
case "$TOKEN" in ''|*[!A-Z0-9_]*) echo "✗ run_detached:--token 只能是大写字母数字下划线" >&2; exit 2 ;; esac

MARK="${TOKEN}_EXIT="
: > "$LOG"
echo "▶ $LABEL —— 后台起,判词只认日志里那一行 ^${MARK}" >&2

# ① 子壳里跑,子壳负责把【命令自己的】退出码追加进日志。
#    这里刻意不用 `cmd &` 再读 $? —— 那读到的是启动它的那一层。
( "$@" >>"$LOG" 2>&1; echo "${MARK}$?" >>"$LOG" ) &
CHILD=$!

# ② 等那一行出现。条件放在 sh -c 里【每一轮重新求值】—— 命令替换会在
#    wait_for 起跑之前就被外层壳算完一次,把条件冻死(AGENTS.md 记过一次 877 秒)。
"$HERE/wait_for.sh" --timeout "$TIMEOUT" --interval "$INTERVAL" \
    --label "$LABEL:脚本自报退出码(^${MARK})" \
    -- sh -c "grep -q '^${MARK}' '$LOG'"
WAITED=$?

# ③ 没拿到那一行 = 判词【未知】,不是失败也不是成功。说出来,不要沉默着变绿。
if [ "$WAITED" -ne 0 ]; then
    kill "$CHILD" 2>/dev/null
    echo "✗ $LABEL:${TIMEOUT}s 内没有等到 ^${MARK} 那一行。" >&2
    echo "  **本脚本因此【不知道】它成没成功 —— 这不是【失败】的证据,也不是【成功】的。**" >&2
    echo "  日志尾巴($LOG):" >&2
    tail -n 15 "$LOG" >&2
    exit 3
fi

REAL=$(grep -m1 "^${MARK}" "$LOG" | sed "s/^${MARK}//")
case "$REAL" in ''|*[!0-9]*)
    echo "✗ $LABEL:那一行读出来不是一个数字(「$REAL」)—— 判词【未知】" >&2; exit 3 ;;
esac
if [ "$REAL" -eq 0 ]; then
    echo "✓ $LABEL:脚本自报 ${MARK}0" >&2
else
    echo "✗ $LABEL:脚本自报 ${MARK}${REAL}" >&2
fi
exit "$REAL"

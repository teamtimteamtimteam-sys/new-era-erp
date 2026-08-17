#!/bin/bash
# scripts/wait-for-deploy.sh — 等一次【指定提交】的 Vercel 部署到 state=success。
#
# ════════════════════════════════════════════════════════════════════════════
# 【为什么是一个脚本,而不是一条手写的 wait_for 命令】
# 2026-08-15(SO-3b fu5 之后)那条手写的等待,一条命令里犯了两个错:
#
#   ① 【标签承诺的和判据检查的不是同一件事】标签写着"部署 state=success",
#      判据却只是 `deployments?sha=… --jq .[0].id | grep -q "[0-9]"` ——
#      它只问"有没有一条部署记录",一次【失败的部署】照样让它变绿。
#      一个说自己在检查 X 而实际检查 Y 的等待,比不检查更坏:它会被信。
#
#   ② 【判据从第一轮起就不可能成立】`?sha=` 只认【完整 40 位】的 SHA。
#      传 7 位缩写进去,GitHub 返回 HTTP 200 + 空数组 —— 不报错,不提示。
#      于是那次等待轮询了 877 秒,而它等的那个部署【早就 success 了】。
#      这正是本仓库反复付账的那条:**一次失败不是一个空集**
#      (mustRows / restRows / check-i18n 的后缀解析,同一条规矩的第四处)。
#      上限救了它 —— 但救的是"多久之后放弃",不是"这条件本来就死了"。
#
# 所以这里把三件手写时容易错的事做成机制:
#   * SHA 一律 `git rev-parse` 成完整 40 位(缩写在这里当场变成完整,
#     而不是在 API 那头变成一个静默的空集);
#   * 判据检查的就是标签承诺的那个字符串 —— state=success;
#   * 【有失败分支】部署落到 failure/error/inactive 时【立刻退出】并点名,
#     不把上限耗光(AGENTS.md:有上限还不够,上限要配一条失败分支)。
#
# 用法:
#     scripts/wait-for-deploy.sh              # 等 HEAD
#     scripts/wait-for-deploy.sh 7a3f519      # 缩写可以,这里会补全
#     scripts/wait-for-deploy.sh HEAD --timeout 1200
#
# 退出码:0 = success · 3 = 超时 · 4 = 部署以失败告终 · 2 = 用法/环境错误
# 成功时打印部署 id、环境 URL,以及【CST 的 success 时刻】—— 那正是切次报告
# 里"破窗"那一栏的终点,不必再手算一次时区。
#
# ── 900 秒的默认上限【实测不够】(GRN-1a,2026-08-17)────────────────────────
# 第一阶段等的是【部署记录出现】,而那一次它花了 **约 37 分钟**:
#   推送 14:48:32Z → 部署记录 created_at 15:25:29Z → success 15:25:30Z。
# 默认上限 900 秒(15 分)因此超时退 3,并印出脚本那句
# "被等的那个东西多半已经死了或从未开始;去看它的日志,不要加大上限"。
# **那句诊断在这一次是错的** —— 它没死,它只是慢。
#
# 【慢在哪一侧,当时没查出来 —— 两个候选,都不要当成结论】
#   (a) Vercel 是【构建完成之后】才登记这条记录的:created_at 与 success 只差
#       1 秒,与这个说法一致,那样 37 分钟里根本没有记录可轮询;
#   (b) GitHub 自己当时就在劣化:同一晚 23:38–23:42 实测 api.github.com 的
#       **GraphQL 连续 HTTP 503**(REST 正常),那么登记延迟也可能出在 GitHub 侧。
# 两者都解释得通这 37 分钟,而【当时没有人去分辨】。写成两个候选而不是一个结论,
# 正是因为上一段刚刚才为"猜一个原因写上去"付过账。
#
# 这条记下来而不是顺手把默认改大,理由有两条:
#   * AGENTS.md 那条二分(快而没出现 = 多半死了)对这一段**不成立**,而一个
#     会说错话的诊断正是本脚本抬头在骂的那种东西 —— 先记录事实,再谈改默认;
#   * 一次测量不是一个分布。同一天早些时候的四次部署都在 **1–2 分钟** 内登记
#     (2f9b47b:提交 12:58:58Z → 记录 13:00:21Z),所以 37 分钟是一条长尾,
#     不是新常态。把默认从 15 分钟拉到 40 分钟,会让【真的挂了】那一类多等
#     半小时才被发现。
#
# **实用做法:知道自己撞上长尾时,显式传 `--timeout 2400`**,而不是改默认。
# 若长尾再出现两三次,那才是改默认(并重写上面那句诊断)的证据。
# ════════════════════════════════════════════════════════════════════════════
set -uo pipefail

REF="HEAD"; TIMEOUT=900
while [ $# -gt 0 ]; do
    case "$1" in
        --timeout) TIMEOUT="${2:-}"; shift 2 ;;
        -*) echo "✗ wait-for-deploy:认不得的参数 $1" >&2; exit 2 ;;
        *) REF="$1"; shift ;;
    esac
done

command -v gh >/dev/null || { echo "✗ wait-for-deploy:PATH 上没有 gh" >&2; exit 2; }
HERE="$(cd "$(dirname "$0")" && pwd)"

# 【缩写在这里就变成完整,不留到 API 那头变成空集】
SHA=$(git rev-parse "$REF" 2>/dev/null) || { echo "✗ wait-for-deploy:解析不了 $REF" >&2; exit 2; }
# ── 仓库名【先从 git remote 本地解析,不走网络】────────────────────────────
# 【为什么不是 gh repo view】那条命令走 GitHub 的 **GraphQL**,而这个脚本别的
# 每一次调用走的都是 **REST**。2026-08-17 实测到两者【会分开坏】:
#     REST  repos/…/deployments  → 正常返回
#     GraphQL api.github.com/graphql → HTTP 503(连续两次)
# 于是这个脚本整个死在启动上,而它真正要做的事(读部署记录与状态)其实完全可用。
# 一个只为"问一句仓库叫什么"而引入的依赖,不该有权否决整个脚本 —— 何况这个
# 问题【根本不需要网络】:答案就在 git remote 里。
#
# 【报出真正的错,不要猜一个】此前这里是 `2>/dev/null || echo "…(gh 没登录?)"`,
# 它把 gh 说的话丢掉,换上一个【自己猜的原因】。上面那次 503 正是被它说成
# "没登录?" 的 —— 而 gh 当时登录得好好的(`gh auth status` 同一分钟内确认),
# 于是排查从第一步就走错了方向。一条声称在说 X、实际没有检查过 X 的消息,
# 比不说更坏(AGENTS.md 反复点名的那一类)。
REPO=$(git config --get remote.origin.url 2>/dev/null \
       | sed -E 's#^git@github\.com:#https://github.com/#; s#^https://[^/]*/##; s#\.git$##')
if [ -z "$REPO" ] || [ "$(printf '%s' "$REPO" | tr -cd '/' | wc -c)" -ne 1 ]; then
    # 兜底才问 gh(可能走 GraphQL,可能因此失败)—— 并且把它的原话原样印出来
    REPO_ERR=$(mktemp)
    REPO=$(gh repo view --json nameWithOwner --jq .nameWithOwner 2>"$REPO_ERR") || {
        echo "✗ wait-for-deploy:问不出仓库。git remote.origin.url 解析不出 owner/repo," >&2
        echo "  退回 gh repo view 也失败了 —— gh 原话:" >&2
        sed 's/^/    /' "$REPO_ERR" >&2
        echo "  (登录状态用 \`gh auth status\` 查;GitHub 的 GraphQL 单独挂掉也会长这样)" >&2
        rm -f "$REPO_ERR"; exit 2
    }
    rm -f "$REPO_ERR"
fi

echo "== 等部署:$REPO @ ${SHA:0:7}(完整 $SHA)"

# ── ① 先等【部署记录出现】——— 推送之后 Vercel 要几秒到几十秒才建它 ────────
# 判据放在 sh -c 的单引号里,于是它【每一轮都重新求值】(RPT-1:命令替换写在
# 参数位置上会被外层 shell 只算一次,把条件冻成一个常量)。
"$HERE/../db/wait_for.sh" --timeout "$TIMEOUT" --label "部署记录出现(${SHA:0:7})" -- \
    sh -c "gh api \"repos/$REPO/deployments?sha=$SHA&per_page=1\" --jq '.[0].id' | grep -qE '^[0-9]+$'" \
    || exit 3

DEP=$(gh api "repos/$REPO/deployments?sha=$SHA&per_page=1" --jq '.[0].id')
echo "== 部署 id $DEP"

# ── ② 再等【状态真的是 success】,并且【失败当场退出】───────────────────────
# 这两件事必须是同一个循环里的两个分支:只等 success 而不认失败,一次失败的
# 部署会把上限耗光,然后报成"超时",而那两件事的下一步完全不同。
DEADLINE=$(( $(date +%s) + TIMEOUT ))
while true; do
    STATE=$(gh api "repos/$REPO/deployments/$DEP/statuses?per_page=1" --jq '.[0].state' 2>/dev/null)
    case "$STATE" in
        success)
            WHEN=$(gh api "repos/$REPO/deployments/$DEP/statuses?per_page=1" --jq '.[0].created_at')
            URL=$(gh api "repos/$REPO/deployments/$DEP/statuses?per_page=1" --jq '.[0].environment_url')
            CST=$(python3 -c "
import datetime as dt,sys
t=dt.datetime.strptime(sys.argv[1],'%Y-%m-%dT%H:%M:%SZ').replace(tzinfo=dt.timezone.utc)
print(t.astimezone(dt.timezone(dt.timedelta(hours=8))).strftime('%F %T CST'))" "$WHEN" 2>/dev/null || echo "$WHEN")
            echo "✓ 部署 success:$URL"
            echo "  success 时刻:$CST  ← 破窗那一栏的【终点】(起点由 apply_migration.sh 打印)"
            exit 0 ;;
        failure|error)
            # 【失败分支】—— 不耗上限,当场点名。这与超时是两回事:
            # 超时说"没等到",这里说"等到了,而它是坏的"。
            echo "✗ 部署以 $STATE 告终(id $DEP)—— 不是超时,是真的失败了" >&2
            echo "   去看 Vercel 的构建日志;不要重试这个等待。" >&2
            exit 4 ;;
    esac
    if [ "$(date +%s)" -ge "$DEADLINE" ]; then
        echo "✗ 等待超时:部署 $DEP state=success" >&2
        echo "   最后看到的状态:${STATE:-<读不到>},上限 ${TIMEOUT}s" >&2
        exit 3
    fi
    sleep 5
done

#!/bin/bash
# db/apply_migration.sh — 迁移直连应用:一条连接、一个事务、要么全上、要么全不上。
#
# 【为什么存在 / OPS-6】此前迁移走 Supabase Management API:载荷 ~15KB 就被掐,
# 连接还反复中断 —— FIN-0 与 FIN-1a 都被迫切块应用,块与块之间没有事务,
# 失败留下半改完的库,靠事后的门才发现。psql 直连(凭据在 ~/.pgpass)一直可用,
# 只是最初没人伸手够它。从本切起:【迁移一律走这里】,Management API 只留给
# 交互式的小查询与回滚型 fixture。
#
# ════════════════════════════════════════════════════════════════════════════
# OPS-7:同两个缺陷重演过之后,这个脚本多做两件事。
#
# 【预防,不是检测】新建的函数留在 anon 可执行,发生过三次(FIN-22 / FIN-23 /
# FIN-27):PostgreSQL 默认把 EXECUTE 授给 PUBLIC,而收回那一步只住在
# db/views/zzz_function_grants.sql 里 —— 重建那一侧会跑到它,线上没有人跑。
# 于是每次都是【重建干净、线上敞开】,只有 db/gate.py 的 B1 事后看得见。
# 现在:迁移应用完,【在同一个事务里】把 zzz_function_grants.sql 再跑一遍。
# 它是纯 GRANT/REVOKE(1 条 GRANT + 9 条 REVOKE,零 CREATE/INSERT/SELECT)、
# 幂等、不假设空库 —— 对着线上跑两遍,178 个函数的 proacl 一个都不变(实测)。
# 于是"线上出现一个没收权的新函数"这件事不再需要被记得,它做不到了。
#
# 【检测那些预防不了的】db/preflight_migration.py 在动库【之前】读一遍迁移文件:
#   * 引用了还没打 is_system 的科目码 → 警告并继续(预检看不到执行后的状态,
#     同一支迁移完全可能自己把它 promote 了,所以它没有资格拒绝);
#   * CREATE OR REPLACE FUNCTION 的签名与线上同名函数不一致 → 【拒绝】。
#     那不是替换是重载,旧签名会原样活下去而镜像里只有一个(FIN-21 的原样重演)。
# 判据是否确定,决定了警告还是拒绝 —— 理由写在那个脚本的抬头。
#
# 跳过预检:PREFLIGHT=0 ./db/apply_migration.sh ...(只在预检本身坏了时用,
# 而且那时该修的是预检)。
# ════════════════════════════════════════════════════════════════════════════
#
# 约定:迁移文件必须自带 BEGIN;/COMMIT;(仓库惯例本就如此)。
# ON_ERROR_STOP=1 让任何错误在 COMMIT 之前中止 —— 服务器端回滚,库分毫不动;
# 连接中断同理(未提交的事务由服务器丢弃)。没有切块,也就没有"恢复点"问题。
set -euo pipefail

FILE=${1:?用法: db/apply_migration.sh db/migrations/<file>.sql}
DSN=${CHECK_MIRRORS_DSN:-"host=aws-1-ap-southeast-1.pooler.supabase.com port=5432 user=postgres.wvywpohbwkiinmipmuku dbname=postgres"}
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GRANTS="$HERE/views/zzz_function_grants.sql"

grep -q '^BEGIN;' "$FILE" || { echo "✗ 迁移文件缺 BEGIN; —— 本仓库的迁移必须整文件一个事务" >&2; exit 2; }
grep -q '^COMMIT;' "$FILE" || { echo "✗ 迁移文件缺 COMMIT;" >&2; exit 2; }
[ -f "$GRANTS" ] || { echo "✗ 找不到 $GRANTS —— 函数授权兜底跑不了,不应用" >&2; exit 2; }

# ── 预检(动库之前)────────────────────────────────────────────────────────
if [ "${PREFLIGHT:-1}" != "0" ]; then
    python3 "$HERE/preflight_migration.py" "$FILE" --dsn "$DSN"
else
    echo "== 预检:已按 PREFLIGHT=0 跳过"
fi

# ── 应用 + 函数授权兜底,同一条连接、同一个事务 ──────────────────────────────
# 迁移文件自带 BEGIN;/COMMIT;。把 COMMIT 换成 zzz + COMMIT,于是授权兜底落在
# 【同一个事务里】:迁移成功而兜底失败时两者一起回滚,不会留下"函数建了、权限
# 没收"的中间态。原文件一个字节不改(只在管道里替换),文件仍是可独立重放的。
echo "== applying $(basename "$FILE") over direct psql (single transaction)"
awk -v g="$GRANTS" '
        /^COMMIT;[[:space:]]*$/ && !done {
            print "\\echo == re-asserting function grants (db/views/zzz_function_grants.sql)"
            print "\\i " g
            done = 1
        }
        { print }
' "$FILE" | psql "$DSN" -X -q -v ON_ERROR_STOP=1 -f -
echo "✓ committed atomically (含函数授权兜底)"

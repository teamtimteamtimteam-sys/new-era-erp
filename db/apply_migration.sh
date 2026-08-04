#!/bin/bash
# db/apply_migration.sh — 迁移直连应用:一条连接、一个事务、要么全上、要么全不上。
#
# 【为什么存在 / OPS-6】此前迁移走 Supabase Management API:载荷 ~15KB 就被掐,
# 连接还反复中断 —— FIN-0 与 FIN-1a 都被迫切块应用,块与块之间没有事务,
# 失败留下半改完的库,靠事后的门才发现。psql 直连(凭据在 ~/.pgpass)一直可用,
# 只是最初没人伸手够它。从本切起:【迁移一律走这里】,Management API 只留给
# 交互式的小查询与回滚型 fixture。
#
# 约定:迁移文件必须自带 BEGIN;/COMMIT;(仓库惯例本就如此)。
# ON_ERROR_STOP=1 让任何错误在 COMMIT 之前中止 —— 服务器端回滚,库分毫不动;
# 连接中断同理(未提交的事务由服务器丢弃)。没有切块,也就没有"恢复点"问题。
set -euo pipefail

FILE=${1:?用法: db/apply_migration.sh db/migrations/<file>.sql}
DSN=${CHECK_MIRRORS_DSN:-"host=aws-1-ap-southeast-1.pooler.supabase.com port=5432 user=postgres.wvywpohbwkiinmipmuku dbname=postgres"}

grep -q '^BEGIN;' "$FILE" || { echo "✗ 迁移文件缺 BEGIN; —— 本仓库的迁移必须整文件一个事务" >&2; exit 2; }
grep -q '^COMMIT;' "$FILE" || { echo "✗ 迁移文件缺 COMMIT;" >&2; exit 2; }

echo "== applying $(basename "$FILE") over direct psql (single transaction)"
psql "$DSN" -X -q -v ON_ERROR_STOP=1 -f "$FILE"
echo "✓ committed atomically"

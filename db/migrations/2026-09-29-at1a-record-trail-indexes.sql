-- db/migrations/2026-09-29-at1a-record-trail-indexes.sql
-- AUDIT-TRAIL-1a(Tim 的 Q6):change_log 上两条 GIN 部分索引 —— 每一页底部的审计记录在【读的时候】找一条记录的子行。
-- 由 db/scripts/build_at1a_migration.py 从镜像(db/tables/change_log.sql)拼出。
--
-- 【为什么它是第二个文件,而且【没有】BEGIN / COMMIT】
--   一句普通的 CREATE INDEX 在 change_log 上拿 SHARE 锁,一直拿到事务提交;而每一次业务写入都要往 change_log 插一行
--   (238 张表的触发器)。放进主迁移,锁会一直拿到 apply_migration.sh 重放完整份授权文件(133 句)再提交 ——
--   2026-09-29 演练实测每句往返 1.5–2 秒,授权那一段约 100 秒,整支 185 秒:业务写入要排队一分多钟,而 authenticated
--   的语句超时是 8 秒,排队的保存会直接报错。
--   CREATE INDEX CONCURRENTLY 不挡写入,但它【不能】在事务块里跑 —— 所以它不走 apply_migration.sh(那支脚本要求
--   BEGIN / COMMIT),而是在主迁移提交之后用 psql 直接跑本文件(自动提交,ON_ERROR_STOP)。
--   两句都是 IF NOT EXISTS,重跑无害。建好之前 record_trail 照样对,只是找子行时少一条索引。
--   跑法:psql "$DSN" -X -v ON_ERROR_STOP=1 -f db/migrations/2026-09-29-at1a-record-trail-indexes.sql

CREATE INDEX CONCURRENTLY IF NOT EXISTS idx_change_log_image ON public.change_log USING gin (COALESCE(new, old) jsonb_path_ops);
CREATE INDEX CONCURRENTLY IF NOT EXISTS idx_change_log_update_old ON public.change_log USING gin (old jsonb_path_ops) WHERE op = 'UPDATE';

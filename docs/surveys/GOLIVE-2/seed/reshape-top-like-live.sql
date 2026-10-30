-- GOLIVE-2 Step 0 · 只对本地一次性库:把种子最新的 7,602 行按每 15 行一笔事务重新分组(≈ 507 笔),
--   让 show=500 读到与线上同样多的行(线上最新 501 笔事务 = 7,602 行,readings/step0-live-counts-b.txt)。
--   用 session_replication_role 绕过 change_log 的只追加触发器 —— 【只在本地一次性库】,永远不对线上。
BEGIN;
SET LOCAL session_replication_role = replica;
WITH top AS (SELECT seq FROM change_log ORDER BY seq DESC LIMIT 7602)
UPDATE change_log c SET txid = 9000000000 + c.seq / 15 FROM top WHERE c.seq = top.seq;
COMMIT;
ANALYZE change_log;
SELECT 'RESHAPE|newest 501 operations now hold ' || count(*) || ' rows' FROM change_log
 WHERE txid IN (SELECT txid FROM change_log GROUP BY txid ORDER BY max(seq) DESC LIMIT 501);

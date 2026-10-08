-- MES-5b-1 · /inventory 的物料平衡合计,迁移之前的算法与之后的算法并排(只读;以 postgres(rolbypassrls = true)读【基表与基视图】)。
--   之前(app/inventory/page.tsx 迁移前 :152-155,:326-328):每一张 deleted_at 为空的加工单的表头 total_input / total_output / loss_qty 之和
--     —— 不分工序种类,放电穿过去的量、拆去隔离的量也算进去。
--   之后(Q12):processing_balance_monthly_all 全厂那几条线的全期之和 —— 只算消耗那几炉(flow = consumption、单位全是 kg);损耗 = 有名字的 + 余数。
--   逐批:每一批喂进那些单的投料量,按两种算法各算一次;再列出新算法把它放在哪一格(消耗 / 拆去隔离 / 穿过去 / 回滚 / 单位不是 kg)。
--   迁移之前跑不了"之后"那一列(视图还不存在)—— 迁移之前的读数是 db/scripts/2026-10-08-mes5b1-opening-readings.sql 第 2 与第 4 段(19:40 与 21:08 CST 两次,逐字相同)。
BEGIN READ ONLY;

\echo '== plant: before (today''s code until this cut) and after (the new view)'
SELECT 'before' AS algo, count(*) AS runs, sum(total_input) AS input, sum(total_output) AS output, sum(loss_qty) AS loss
  FROM processing_runs WHERE deleted_at IS NULL
UNION ALL
SELECT 'after', (SELECT sum(runs) FROM processing_balance_monthly_all WHERE scope = 'plant' AND line = 'input'),
       (SELECT sum(qty) FROM processing_balance_monthly_all WHERE scope = 'plant' AND line = 'input'),
       (SELECT sum(qty) FROM processing_balance_monthly_all WHERE scope = 'plant' AND line = 'output'),
       (SELECT sum(qty) FROM processing_balance_monthly_all WHERE scope = 'plant' AND line IN ('loss', 'remainder'));

\echo '== per batch'
SELECT COALESCE(ib.code, ob.code) AS batch,
       CASE WHEN pi.inbound_batch_id IS NOT NULL THEN 'inbound' ELSE 'output' END AS side,
       sum(pi.quantity_consumed) FILTER (WHERE r.deleted_at IS NULL) AS before_counted,
       sum(pi.quantity_consumed) FILTER (WHERE f.flow = 'consumption' AND NOT f.not_kg) AS after_consumed,
       sum(pi.quantity_consumed) FILTER (WHERE f.flow = 'transfer') AS after_split,
       sum(pi.quantity_consumed) FILTER (WHERE f.flow = 'pass_through') AS after_pass_through,
       sum(pi.quantity_consumed) FILTER (WHERE f.flow = 'reversed') AS after_reversed_listed,
       sum(pi.quantity_consumed) FILTER (WHERE f.flow = 'consumption' AND f.not_kg) AS after_not_kg,
       string_agg(DISTINCT r.code || ':' || f.flow, ', ') AS runs
  FROM processing_inputs pi
  JOIN processing_runs r ON r.id = pi.run_id
  JOIN processing_run_flow_all f ON f.run_id = r.id
  LEFT JOIN inbound_batches ib ON ib.id = pi.inbound_batch_id
  LEFT JOIN output_batches ob ON ob.id = pi.output_batch_id
 GROUP BY 1, 2 ORDER BY 2, 1;

\echo '== per batch: the tree''s own top lines (received = Σ fates; unexplained must be 0)'
SELECT root_code, root_kind,
       max(x) FILTER (WHERE node_type = 'batch') AS received,
       string_agg(line_key || '=' || x, ' · ' ORDER BY line_key) FILTER (WHERE node_type = 'fate' AND x <> 0) AS fates,
       max(x) FILTER (WHERE node_type = 'fate' AND line_key = 'unexplained') AS unexplained
  FROM batch_balance_tree_all WHERE parent_key IS NULL OR parent_key = 'r'
 GROUP BY root_code, root_kind
HAVING max(x) FILTER (WHERE node_type = 'fate' AND line_key = 'unexplained') <> 0
    OR EXISTS (SELECT 1 FROM processing_inputs pi WHERE pi.inbound_batch_id = (array_agg(root_id))[1] OR pi.output_batch_id = (array_agg(root_id))[1])
 ORDER BY root_kind, root_code;

\echo '== every batch: unexplained must be 0 (count of batches where it is not)'
SELECT count(*) AS batches, count(*) FILTER (WHERE x <> 0) AS unexplained_nonzero
  FROM batch_balance_tree_all WHERE parent_key = 'r' AND node_type = 'fate' AND line_key = 'unexplained';
ROLLBACK;

-- db/views/batch_lineage_all.sql
-- AUD-1:batch_lineage 的【无判据基视图】。
--
-- 【为什么要拆】属主权限替得了视图引用的表/视图的权限,**替不了体内那句
-- has_permission —— 它按【调用者】解析**(AGENTS.md 那一节,已经被发现三次)。
-- 于是一个只持 module.sales.view 的读者,经由 traceability_report_data(它自己的门
-- 是 sales OR processing)去读带判据的 batch_lineage,拿到的是【零行】——
-- 而零行在这里的意思会变成"这个批次没有来源",一个错的好消息(OPS-14 的
-- xmodule 那一课)。修法就是那一节写明的:判据挪到外层,内层留这一张
-- (先例 stock_class_violations_all)。
--
-- 【不授权给任何人】它是内层算子,靠"够不着"把关;对外读 batch_lineage。
-- 实测(AUD-1 注入 2):把报告改回读带判据的那一张,fixture 83 当场红在
-- 只持 sales.view 的那一臂上 —— 症状正是 NOTHING_TO_REPORT,一个假阴性。
--
-- NOTE: introduced by db/migrations/2026-08-17-aud1-traceability-report.sql
-- (body lifted verbatim from batch_lineage, FIN-25).

CREATE VIEW public.batch_lineage_all AS
 WITH RECURSIVE up AS (
         SELECT po.output_batch_id AS batch_id,
            pr.id AS via_run_id,
            pr.code AS via_run_code,
            pi.inbound_batch_id AS parent_inbound_id,
            pi.output_batch_id AS parent_output_id,
            pi.quantity_consumed,
            1 AS depth
           FROM processing_outputs po
             JOIN processing_runs pr ON pr.id = po.run_id AND pr.deleted_at IS NULL
             JOIN processing_inputs pi ON pi.run_id = pr.id
        UNION ALL
         SELECT up_1.batch_id,
            pr2.id,
            pr2.code,
            pi2.inbound_batch_id,
            pi2.output_batch_id,
            pi2.quantity_consumed,
            up_1.depth + 1
           FROM up up_1
             JOIN processing_outputs po2 ON po2.output_batch_id = up_1.parent_output_id
             JOIN processing_runs pr2 ON pr2.id = po2.run_id AND pr2.deleted_at IS NULL
             JOIN processing_inputs pi2 ON pi2.run_id = pr2.id
          WHERE up_1.parent_output_id IS NOT NULL
        )
 SELECT up.batch_id AS output_batch_id,
    up.depth,
    up.via_run_id,
    up.via_run_code,
        CASE
            WHEN up.parent_inbound_id IS NOT NULL THEN 'inbound'::text
            ELSE 'output'::text
        END AS parent_kind,
    COALESCE(up.parent_inbound_id, up.parent_output_id) AS parent_batch_id,
    COALESCE(ib.code, ob.code) AS parent_code,
    up.quantity_consumed
   FROM up
     LEFT JOIN inbound_batches ib ON ib.id = up.parent_inbound_id
     LEFT JOIN output_batches ob ON ob.id = up.parent_output_id;

COMMENT ON VIEW public.batch_lineage_all IS
    'AUD-1:batch_lineage 的【无判据基视图】。属主权限替得了表的权限,替不了体内 has_permission(它按调用者解析)—— 所以要让一个只持 module.sales.view 的读者经由 traceability_report_data 读到血缘,判据必须挪到外层,内层留这一张(先例 stock_class_violations_all)。【不授权给任何人】,靠够不着把关;对外读 batch_lineage。';

-- db/views/assay_disagreements_all.sql
-- MES-6a-1(2026-10-09,MES-0 Q62 · MES-6a Step 0 Q17,Tim):【卖方:两方结果差得超过了合同的容差,而没有人立过争议】—— 底表,只给属主读。
--   operations_now 的 assay_results_disagree 那一支读它(Q62:"只在有容差的地方提示")。
--   一行 = 一批产出批 × 一张与它有关的销售单(经预留、发货行或结算记录挂上的),那张单的合同副本里有容差(splitting_limit_pct 不空),
--   这一批最近一份没删的 ours 与最近一份没删的 counterparty 在两份都有的元素上的最大差超过了它(与 sale_settlement_compute 那一道推出来的
--   拒绝同一个算法),而这一批没有一件开着或已结案的争议(撤回过的不算 —— 两份数仍然对不上,提示回来)。
--   【买方没有这一支】买方合同今天不带结算口径,所以买方没有容差可比(Q17 —— 买方的争议由人自己立)。
--   【底表】authenticated 读不到(zzz_function_grants 一侧的同一个理由:提醒外壳按每一支的码把门)。
-- NOTE: introduced by db/migrations/2026-10-09-mes6a1-samples-and-disputes.sql.

CREATE VIEW public.assay_disagreements_all WITH (security_invoker = off) AS
 SELECT ob.id AS output_batch_id,
    ob.code AS batch_code,
    so.id AS sales_order_id,
    so.code AS sales_order_code,
    o.id AS our_assay_id,
    o.code AS our_assay_code,
    c.id AS counterparty_assay_id,
    c.code AS counterparty_assay_code,
    (t.settlement_terms ->> 'splitting_limit_pct'::text)::numeric AS limit_pct,
    x.max_diff_pct,
    GREATEST(o.assay_date, c.assay_date) AS latest_assay_date
   FROM output_batches ob
     CROSS JOIN LATERAL ( SELECT a.id, a.code, a.assay_date
           FROM assay_results a
          WHERE a.output_batch_id = ob.id AND a.deleted_at IS NULL AND a.result_party = 'ours'::text
          ORDER BY a.assay_date DESC, a.code DESC
         LIMIT 1) o
     CROSS JOIN LATERAL ( SELECT a.id, a.code, a.assay_date
           FROM assay_results a
          WHERE a.output_batch_id = ob.id AND a.deleted_at IS NULL AND a.result_party = 'counterparty'::text
          ORDER BY a.assay_date DESC, a.code DESC
         LIMIT 1) c
     CROSS JOIN LATERAL ( SELECT max(abs(om.content_pct - cm.content_pct)) AS max_diff_pct
           FROM assay_result_metals om
             JOIN assay_result_metals cm ON cm.metal = om.metal AND cm.assay_result_id = c.id
          WHERE om.assay_result_id = o.id) x
     JOIN ( SELECT r.output_batch_id, l.sales_order_id
           FROM sales_order_reservations r
             JOIN sales_order_lines l ON l.id = r.sales_order_line_id
        UNION
         SELECT sl.output_batch_id, l.sales_order_id
           FROM shipment_lines sl
             JOIN sales_order_lines l ON l.id = sl.sales_order_line_id
        UNION
         SELECT st.output_batch_id, st.sales_order_id
           FROM sales_settlements st) link ON link.output_batch_id = ob.id
     JOIN sales_orders so ON so.id = link.sales_order_id AND so.deleted_at IS NULL
     JOIN contract_document_terms t ON t.sales_order_id = so.id
  WHERE ob.deleted_at IS NULL AND (t.settlement_terms ->> 'splitting_limit_pct'::text) IS NOT NULL
    AND x.max_diff_pct > (t.settlement_terms ->> 'splitting_limit_pct'::text)::numeric
    AND NOT (EXISTS ( SELECT 1
           FROM assay_disputes d
          WHERE d.output_batch_id = ob.id AND (d.status = ANY (ARRAY['open'::text, 'resolved'::text]))));

COMMENT ON VIEW public.assay_disagreements_all IS
    'MES-6a-1:卖方 —— 一批产出批最近一份 ours 与最近一份 counterparty 的最大差超过了一张与它有关的销售单的合同容差,而没有开着或已结案的争议(MES-0 Q62 的提示)。底表,只给属主读;operations_now 的 assay_results_disagree 读它。';

REVOKE ALL ON public.assay_disagreements_all FROM authenticated, anon;

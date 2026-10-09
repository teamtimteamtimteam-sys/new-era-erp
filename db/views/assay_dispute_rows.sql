-- db/views/assay_dispute_rows.sql
-- MES-6a-1(2026-10-09,MES-6a Step 0 Q16 · Q19 · Q22,Tim):【一件化验争议,连同它的两份(三份)结果、容差、结案与仲裁费】——
--   争议清单、争议页、批次与化验页上的争议横幅读它。
--   max_diff_pct = 我们与对手方在【两份都有】的元素上的最大差(与 sale_settlement_compute 那一道推出来的拒绝同一个算法);
--   beyond_limit = 它是否超过立案时在案的容差(容差为空 → NULL,判不了 —— limit not set)。
--   【仲裁费】fee_amount_base 是挂上的那张费用单的本位币净额;counterparty_share_pct 是按立案时在案的规则(V14)算出来的对手方那一份
--   (只算给人看,不收 —— Q22):equal 50 · buyer / seller 看这一批是卖出去的(产出批:对手方是买方)还是买进来的(进料批:我们是买方)·
--   loser_pays 看结案时点名的那一份是谁的(说了算的是我们 → 对手方付;是对手方 → 我们付;是仲裁的 → 照 further_from_umpire_pays)·
--   further_from_umpire_pays 看两份各自离仲裁结果多远(在三份都有的元素上取最大差;一样远或缺一样 → NULL)。规则为空或算不了 → NULL。
--   ★ 钱的那两列(费用额、对手方那一份的额)只给持 module.finance.view 的读者(常设决定 1:持财务查看就看得见钱);其余读到 NULL,
--   fee_restricted 为真 —— 屏幕上是「受限」,不是 0。规则、比例与费用单号不遮。
--   【门】质量查看码,或那一批自己那一页的查看码(与 assay_disputes 的读策略同一句)。属主视图,条件在末尾的 WHERE 里。
-- NOTE: introduced by db/migrations/2026-10-09-mes6a1-samples-and-disputes.sql.

CREATE VIEW public.assay_dispute_rows WITH (security_invoker = off) AS
 SELECT d.id,
    d.status,
    d.inbound_batch_id,
    d.output_batch_id,
    COALESCE(ib.code, ob.code) AS batch_code,
        CASE
            WHEN d.inbound_batch_id IS NOT NULL THEN 'inbound'::text
            ELSE 'output'::text
        END AS batch_kind,
    d.our_assay_id,
    ao.code AS our_assay_code,
    d.counterparty_assay_id,
    ac.code AS counterparty_assay_code,
    d.umpire_sample_id,
    us.code AS umpire_sample_code,
    d.umpire_assay_id,
    au.code AS umpire_assay_code,
    au.lab_name AS umpire_lab_code,
    d.governing_assay_id,
    ag.code AS governing_assay_code,
    ag.result_party AS governing_party,
    d.sales_order_id,
    so.code AS sales_order_code,
    d.opening_reason,
    d.limit_pct_at,
    x.max_diff_pct,
        CASE
            WHEN d.limit_pct_at IS NULL OR x.max_diff_pct IS NULL THEN NULL::boolean
            ELSE x.max_diff_pct > d.limit_pct_at
        END AS beyond_limit,
    d.fee_rule_at,
    d.fee_expense_id,
    fe.code AS fee_expense_code,
        CASE
            WHEN has_permission('module.finance.view'::text) THEN fe.amount_base
            ELSE NULL::numeric
        END AS fee_amount_base,
    sh.share_pct AS counterparty_share_pct,
        CASE
            WHEN has_permission('module.finance.view'::text) THEN round(fe.amount_base * sh.share_pct / 100::numeric, 2)
            ELSE NULL::numeric
        END AS counterparty_share_base,
    d.fee_expense_id IS NOT NULL AND NOT has_permission('module.finance.view'::text) AS fee_restricted,
    d.resolution_note,
    d.resolved_at,
    d.resolved_by,
    d.withdrawn_at,
    d.withdrawn_by,
    d.withdraw_reason,
    d.created_at,
    d.created_by
   FROM assay_disputes d
     LEFT JOIN inbound_batches ib ON ib.id = d.inbound_batch_id
     LEFT JOIN output_batches ob ON ob.id = d.output_batch_id
     JOIN assay_results ao ON ao.id = d.our_assay_id
     JOIN assay_results ac ON ac.id = d.counterparty_assay_id
     LEFT JOIN assay_results au ON au.id = d.umpire_assay_id
     LEFT JOIN assay_results ag ON ag.id = d.governing_assay_id
     LEFT JOIN samples us ON us.id = d.umpire_sample_id
     LEFT JOIN sales_orders so ON so.id = d.sales_order_id
     LEFT JOIN expenses fe ON fe.id = d.fee_expense_id
     CROSS JOIN LATERAL ( SELECT max(abs(o.content_pct - c.content_pct)) AS max_diff_pct
           FROM assay_result_metals o
             JOIN assay_result_metals c ON c.metal = o.metal AND c.assay_result_id = d.counterparty_assay_id
          WHERE o.assay_result_id = d.our_assay_id) x
     CROSS JOIN LATERAL ( SELECT max(abs(o.content_pct - u.content_pct)) AS ours_from_umpire,
            max(abs(c.content_pct - u.content_pct)) AS cp_from_umpire
           FROM assay_result_metals u
             JOIN assay_result_metals o ON o.metal = u.metal AND o.assay_result_id = d.our_assay_id
             JOIN assay_result_metals c ON c.metal = u.metal AND c.assay_result_id = d.counterparty_assay_id
          WHERE u.assay_result_id = d.umpire_assay_id) dist
     CROSS JOIN LATERAL ( SELECT
                CASE d.fee_rule_at
                    WHEN 'equal'::text THEN 50::numeric
                    WHEN 'buyer'::text THEN
                    CASE
                        WHEN d.output_batch_id IS NOT NULL THEN 100::numeric
                        ELSE 0::numeric
                    END
                    WHEN 'seller'::text THEN
                    CASE
                        WHEN d.output_batch_id IS NOT NULL THEN 0::numeric
                        ELSE 100::numeric
                    END
                    WHEN 'loser_pays'::text THEN
                    CASE ag.result_party
                        WHEN 'ours'::text THEN 100::numeric
                        WHEN 'counterparty'::text THEN 0::numeric
                        WHEN 'umpire'::text THEN
                        CASE
                            WHEN dist.cp_from_umpire > dist.ours_from_umpire THEN 100::numeric
                            WHEN dist.ours_from_umpire > dist.cp_from_umpire THEN 0::numeric
                            ELSE NULL::numeric
                        END
                        ELSE NULL::numeric
                    END
                    WHEN 'further_from_umpire_pays'::text THEN
                    CASE
                        WHEN dist.cp_from_umpire > dist.ours_from_umpire THEN 100::numeric
                        WHEN dist.ours_from_umpire > dist.cp_from_umpire THEN 0::numeric
                        ELSE NULL::numeric
                    END
                    ELSE NULL::numeric
                END AS share_pct) sh
  WHERE has_permission('module.quality.view'::text) OR d.inbound_batch_id IS NOT NULL AND has_permission('module.inbound.view'::text) OR d.output_batch_id IS NOT NULL AND has_permission('module.output.view'::text);

COMMENT ON VIEW public.assay_dispute_rows IS
    'MES-6a-1:一件化验争议,连同它的结果、最大差、容差(立案时在案;空 = limit not set)、结案、仲裁费与对手方那一份(按立案时的 V14 规则算,只给人看,不收)。钱的两列只给 module.finance.view(常设决定 1),其余 NULL + fee_restricted。门:质量查看码或那一批自己的查看码。';

GRANT SELECT ON public.assay_dispute_rows TO authenticated;
REVOKE ALL ON public.assay_dispute_rows FROM anon;

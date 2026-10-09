-- db/views/assay_dispute_metals.sql
-- MES-6a-1(2026-10-09,MES-6a Step 0 Q16,Tim):【一件争议逐元素的差 —— 现算,不存】。争议页的"两份结果并排"那一段读它。
--   一行一种元素:我们的 % · 对手方的 % · 仲裁的 %(记了仲裁结果时)· |我们 − 对手方| · 是否超过立案时在案的容差
--   (容差为空 = limit not set → beyond_limit 为 NULL,"判不了",不是"没超")。一种元素只在一份结果里有 → 另一侧为 NULL、差为 NULL。
--   【门】质量查看码,或那一批自己那一页的查看码(与 assay_disputes 的读策略同一句)。属主视图:化验的金属不再过各自那一批的 RLS,
--   所以条件写在末尾的 WHERE 里一次。含量是技术数据(perm2b 有意不遮 content_pct),不遮。
-- NOTE: introduced by db/migrations/2026-10-09-mes6a1-samples-and-disputes.sql.

CREATE VIEW public.assay_dispute_metals WITH (security_invoker = off) AS
 SELECT d.id AS dispute_id,
    m.metal,
    o.content_pct AS ours_pct,
    c.content_pct AS counterparty_pct,
    u.content_pct AS umpire_pct,
    abs(o.content_pct - c.content_pct) AS diff_pct,
        CASE
            WHEN d.limit_pct_at IS NULL OR o.content_pct IS NULL OR c.content_pct IS NULL THEN NULL::boolean
            ELSE abs(o.content_pct - c.content_pct) > d.limit_pct_at
        END AS beyond_limit
   FROM assay_disputes d
     CROSS JOIN LATERAL ( SELECT x.metal
           FROM assay_result_metals x
          WHERE x.assay_result_id = ANY (ARRAY[d.our_assay_id, d.counterparty_assay_id, d.umpire_assay_id])
          GROUP BY x.metal) m
     LEFT JOIN assay_result_metals o ON o.assay_result_id = d.our_assay_id AND o.metal = m.metal
     LEFT JOIN assay_result_metals c ON c.assay_result_id = d.counterparty_assay_id AND c.metal = m.metal
     LEFT JOIN assay_result_metals u ON u.assay_result_id = d.umpire_assay_id AND u.metal = m.metal
  WHERE has_permission('module.quality.view'::text) OR d.inbound_batch_id IS NOT NULL AND has_permission('module.inbound.view'::text) OR d.output_batch_id IS NOT NULL AND has_permission('module.output.view'::text);

COMMENT ON VIEW public.assay_dispute_metals IS
    'MES-6a-1:一件化验争议逐元素的差(现算,不存 —— Q16):我们的 / 对手方的 / 仲裁的 %,|我们 − 对手方|,是否超过立案时在案的容差(容差为空 → NULL,判不了)。门:质量查看码或那一批自己的查看码。';

GRANT SELECT ON public.assay_dispute_metals TO authenticated;
REVOKE ALL ON public.assay_dispute_metals FROM anon;

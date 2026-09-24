-- db/views/pricing_term_commitment_metals_masked.sql
-- ★ ROLE-1 Batch 4a(2026-09-25,Tim 的 Q9 线):本视图是【采购那一侧】的价格 —— 遮蔽码从 data.view_prices
--   换成 data.view_purchase_prices(今天持 view_prices 的每一个角色一并拿到它,仓库只拿它)。
-- 遮蔽伴生视图:pricing_term_commitment_metals 的每一列都在,敏感列按 has_permission() 置空。
--   遮蔽的列:payable_pct → data.view_prices(与 pricing_formula_metals 同口径)。
--
-- 属主权限 + 模块谓词原样加回,理由同 pricing_term_commitments_masked。
--
-- NOTE: introduced by db/migrations/2026-08-07-fin27-pricing-terms-commitment.sql.

CREATE VIEW public.pricing_term_commitment_metals_masked WITH (security_invoker = off) AS
 SELECT commitment_id,
    metal,
        CASE
            WHEN has_permission('data.view_purchase_prices'::text) THEN payable_pct
            ELSE NULL::numeric
        END AS payable_pct
   FROM pricing_term_commitment_metals
  WHERE has_permission('module.purchasing.view'::text) OR has_permission('module.inbound.view'::text);

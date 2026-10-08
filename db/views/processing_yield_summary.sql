-- db/views/processing_yield_summary.sql
-- MES-5b-1(2026-10-08,MES-5b Step 0 Q14 · Q32,Tim):【得率的分组合计 —— 带门的外壳】。/operation/yield 读它。门 module.processing.view。
--   分组的标签(group_label):
--     machine   —— 机器的资产编号与名称(fixed_assets.code · description)—— 标签跟着这一行走(AGENTS.md 常设决定 3)
--     chemistry —— 化学体系的代码(battery_chemistries.code);空 = 化学体系没记
--     supplier  —— 供应商的法定名称,【只给持 module.inbound.view 的人】:供应商经进料批而来,标签跟着那张批次自己的查看码走(Q14 · Q32)。
--                  不持它的人 group_label 为空、group_label_restricted 为真 —— 页面画「受限」;group_key 为空(源头不是进料批)时
--                  group_label_restricted 为假、页面画"不是来自进料批"。一个 NULL 不许同时表示"受限"与"没有"(AGENTS.md「NULL 有没有主」)。
--
-- NOTE: introduced by db/migrations/2026-10-08-mes5b1-balance-and-yield.sql.

CREATE VIEW public.processing_yield_summary WITH (security_invoker = off) AS
 SELECT s.group_kind,
    s.group_key,
        CASE s.group_kind
            WHEN 'machine'::text THEN (fa.code || ' · '::text) || fa.description
            WHEN 'chemistry'::text THEN s.group_key
            WHEN 'supplier'::text THEN
            CASE
                WHEN has_permission('module.inbound.view'::text) THEN sp.legal_name
                ELSE NULL::text
            END
            ELSE NULL::text
        END AS group_label,
    s.group_kind = 'supplier'::text AND s.group_key IS NOT NULL AND NOT has_permission('module.inbound.view'::text) AS group_label_restricted,
    s.operation_type_code,
    s.month,
    s.line_kind,
    s.line_key,
    s.recoverable,
    s.qty,
    s.input_qty,
    s.runs,
    s.pre_mes4a_runs,
    s.yield_pct,
    s.expected_yield_pct,
    s.below_expected
   FROM processing_yield_summary_all s
     LEFT JOIN fixed_assets fa ON s.group_kind = 'machine'::text AND fa.id::text = s.group_key
     LEFT JOIN suppliers sp ON s.group_kind = 'supplier'::text AND sp.id::text = s.group_key
  WHERE has_permission('module.processing.view'::text);

COMMENT ON VIEW public.processing_yield_summary IS
    'MES-5b-1:得率的分组合计,带门(module.processing.view);供应商的名字只给持 module.inbound.view 的人(否则 group_label_restricted = true),机器与化学体系的标签跟着行走。算术全在 processing_yield_summary_all。';

GRANT SELECT ON public.processing_yield_summary TO authenticated;
REVOKE ALL ON public.processing_yield_summary FROM anon;

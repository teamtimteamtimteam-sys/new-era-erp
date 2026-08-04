-- db/views/processing_cost_entries_masked.sql
-- 遮蔽伴生视图:processing_cost_entries 的每一列都在,敏感列按 has_permission() 置空。
--   遮蔽的列:amount_base → data.view_prices
--
-- 【"每一列都在"曾经是假的】FIN-6 给基表加了四列结算列,没有同步加进这里,于是
-- 经视图选 remitted_at 会 42703,而基表那条路又因列清单授权没延伸而 42501 ——
-- 两条路都不通,/finance/processing-costs 从上线起就是空页。四列已于
-- 2026-08-04-fin7-fu-masked-grant-gaps 补入(CREATE OR REPLACE 只能加在末尾,
-- 所以它们不按基表 attnum 顺序排,而在最后)。加列必须同时改这里和授权清单。
--
-- 【属主权限,不是 SECURITY INVOKER】。invoker 视图以调用者身份读基表,于是任何
-- 强到能挡住原始列的机制(收紧行策略、或收回列权限)同样会挡住视图本身 —— 实测
-- 分别得到 0 行与 42501。因此这里用属主权限,并【把模块谓词原样加回视图体】:
--     WHERE has_permission('module.processing.view')
-- cut 2a 的 SELECT 策略恰好就是这同一个布尔量(与行内容无关,整表要么全可见要么
-- 全不可见),所以这与调用者的 RLS 逐行等价 —— 视图【不放宽任何行访问】。
--
-- NOTE: introduced by db/migrations/2026-08-01-perm2b-field-masking.sql.

CREATE VIEW public.processing_cost_entries_masked WITH (security_invoker = off) AS
 SELECT id,
    run_id,
    cost_type,
        CASE
            WHEN has_permission('data.view_prices'::text) THEN amount_base
            ELSE NULL::numeric
        END AS amount_base,
    is_estimate,
    notes,
    deleted_at,
    created_at,
    created_by,
    updated_at,
    updated_by,
    remitted_at,
    remitted_journal_entry_id,
    relieved_at,
    relief_expense_id
   FROM processing_cost_entries
  WHERE has_permission('module.processing.view'::text);

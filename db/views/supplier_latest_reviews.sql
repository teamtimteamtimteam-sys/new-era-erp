-- db/views/supplier_latest_reviews.sql
-- MES-8a(2026-10-16,MES-8 Step 0 Q2):【一家供应商最近一次没有被取代的评审】—— 一处定义,三个读者:采购单的等级建议
--   (supplier_grade_advice_internal → create_purchase_order 的警告 · 表单 · 收货页的抽样建议)、评分卡页(supplier_scorecard_rows)与
--   "该评了"的提醒(operations_now 的 supplier_review_due)。被另一次评审更正过的那一次就是被取代;"最近"按 seq(bigserial)排 ——
--   recorded_at 是事务开始的时刻,同一笔事务里两次评审排不出先后(AGENTS.md「取最新那一行」)。
--   【invoker】读规则就是 supplier_scorecard_reviews 自己的(module.suppliers.view);属主权限的调用者读全部。
-- NOTE: introduced by db/migrations/2026-10-16-mes8a-supplier-scorecards-and-statements.sql.
-- First-run script. Re-running requires DROP VIEW first.

CREATE VIEW public.supplier_latest_reviews WITH (security_invoker = on) AS
 SELECT DISTINCT ON (r.supplier_id) r.id,
    r.seq,
    r.supplier_id,
    r.window_from,
    r.window_to,
    r.grade,
    r.score,
    r.not_graded_reason,
    r.grade_caps,
    r.recorded_at
   FROM supplier_scorecard_reviews r
  WHERE NOT (EXISTS ( SELECT 1
           FROM supplier_scorecard_reviews c
          WHERE c.corrects_review_id = r.id))
  ORDER BY r.supplier_id, r.seq DESC;

COMMENT ON VIEW public.supplier_latest_reviews IS
    'MES-8a:每一家供应商最近一次(按 seq)没有被取代的评审 —— 采购单的等级建议、评分卡页与 supplier_review_due 共用这一份。invoker(module.suppliers.view)。';

-- F16:平台的默认权限给新视图授了 authenticated 的写 —— 先全收,再只授 SELECT(MES-7b-1 的惯例;迁移收尾的 F16 断言在 zzz 重放之前就要读到 0)
REVOKE ALL ON public.supplier_latest_reviews FROM authenticated, anon;
GRANT SELECT ON public.supplier_latest_reviews TO authenticated;

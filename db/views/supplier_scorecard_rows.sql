-- db/views/supplier_scorecard_rows.sql
-- MES-8a(2026-10-16,MES-8 Step 0 Q2 · Q5 · Q91):评分卡页(/suppliers/scorecards)一家供应商一行 —— 它最近一次【没有被取代】的评审
--   (按 seq)的窗口、等级、分、为什么没评级、记的时刻,以及它一共被评过几次。没有评审的供应商照样一行(那几列是空,屏幕说"Not reviewed")。
--   最近那一次读 supplier_latest_reviews(一处定义)。
--   【invoker】一个模块:suppliers 与 supplier_scorecard_reviews 的读规则都是 module.suppliers.view,不会有一侧被静默丢掉。
-- NOTE: introduced by db/migrations/2026-10-16-mes8a-supplier-scorecards-and-statements.sql.
-- First-run script. Re-running requires DROP VIEW first.

CREATE VIEW public.supplier_scorecard_rows WITH (security_invoker = on) AS
 SELECT s.id AS supplier_id,
    s.code AS supplier_code,
    s.legal_name AS supplier_name,
    s.status AS supplier_status,
    s.counterparty_type,
    lr.id AS review_id,
    lr.window_from,
    lr.window_to,
    lr.grade,
    lr.score,
    lr.not_graded_reason,
    lr.recorded_at,
    ( SELECT count(*) AS count
           FROM supplier_scorecard_reviews r2
          WHERE r2.supplier_id = s.id) AS review_count
   FROM suppliers s
     LEFT JOIN supplier_latest_reviews lr ON lr.supplier_id = s.id
  WHERE s.deleted_at IS NULL;

COMMENT ON VIEW public.supplier_scorecard_rows IS
    'MES-8a:评分卡页一家供应商一行 —— 最近一次没被取代的评审(按 seq)的窗口、等级、分、没评级的理由与时刻,与评过几次。没有评审照样一行。invoker:两张表同一个读规则 module.suppliers.view。';

-- F16:平台的默认权限给新视图授了 authenticated 的写 —— 先全收,再只授 SELECT(MES-7b-1 的惯例;迁移收尾的 F16 断言在 zzz 重放之前就要读到 0)
REVOKE ALL ON public.supplier_scorecard_rows FROM authenticated, anon;
GRANT SELECT ON public.supplier_scorecard_rows TO authenticated;

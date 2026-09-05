-- db/migrations/2026-09-05-fix2a-fu1-cost-entry-state-columns.sql
-- FIX-2a fu1(2026-09-05)· 冒烟抓到的两处 42703
--
-- ════════════════════════════════════════════════════════════════════════════
-- 【它是怎么被抓到的,以及为什么不是被【类型】抓到的】
--
-- `npx tsc --noEmit` 退 0,`npm run build` 退 0,而 `/finance/month-end` 与
-- `/finance/processing-costs` 两页在冒烟里【双双 500】:
--
--     42703 column processing_cost_entry_lookup.remitted_at does not exist
--
-- 原因:两页取"还欠着的计提"时,过滤条件是
--     .is('deleted_at', null).is('remitted_at', null).is('relieved_at', null)
-- 而 FIX-2a 建 processing_cost_entry_lookup 时【只看了 select 列表】,
-- 没有看那条 `.is()` 链。**过滤用到的列与选出来的列是两份清单,而只有一份被读了。**
--
-- ★ 这正是 AGENTS.md 那条「Type-check green is NOT proof the app runs」的
--   数据版:PostgREST 的列名是【运行期】才解析的字符串,类型系统看不见它。
--   本刀因此顺手写了一支扫描器(见报告),把"每一个改指过的调用点,
--   它 select 的列【与它过滤/排序用的列】是不是都在那张视图上"一次问完 ——
--   两处,一次全找出来,而不是修一处、跑一次冒烟、再修一处。
--
-- 【为什么这两列可以加 —— 它们不是钱】
--   remitted_at / relieved_at 是【状态时点】:这条计提汇缴了没有、冲销了没有。
--   金额那一列(amount_base)仍然按 data.view_prices 遮,一个字没动。
--   月结与加工成本两页要回答的正是"还欠着哪些",而那个问题问的就是这两列。
--
-- ★ CREATE OR REPLACE VIEW 只许在【末尾追加】列,所以两列加在最后。
--   而它还会【丢掉 WITH (...)】—— 见下面那句 ALTER(FIX-2a 主迁移已经栽过一次)。
--
-- 镜像:db/views/processing_cost_entry_lookup.sql
-- 行为断言:db/fixtures/194(C 臂已覆盖这张视图;本 fu 不改它的判据)
-- ════════════════════════════════════════════════════════════════════════════

BEGIN;

CREATE OR REPLACE VIEW public.processing_cost_entry_lookup AS
 SELECT e.id,
    e.run_id,
    e.cost_type,
    e.is_estimate,
    e.created_at,
    e.deleted_at,
        CASE
            WHEN has_permission('data.view_prices'::text) THEN e.amount_base
            ELSE NULL::numeric
        END AS amount_base,
    -- fu1:两个【状态时点】—— 汇缴了没有 / 冲销了没有。不是金额。
    e.remitted_at,
    e.relieved_at
   FROM processing_cost_entries e
  WHERE has_permission('module.processing.view'::text)
     OR has_permission('module.finance.view'::text);

ALTER VIEW public.processing_cost_entry_lookup SET (security_invoker = off);

COMMENT ON VIEW public.processing_cost_entry_lookup IS
    'FIX-2a:加工成本条目的【查名】视图 —— id / 加工单 / 成本类型 / 是否估算 / 创建时间 / 汇缴与冲销时点,外加按 data.view_prices 遮的金额(与 processing_cost_entries_masked 同一条列谓词)。财务的分录、总账、月结与加工成本四处要把一条分录指回它的来源单据,并回答"还欠着哪些"。fu1 补了 remitted_at / relieved_at:它们是状态时点不是钱,而两页的 .is() 过滤链要它们 —— 主迁移只读了 select 列表、没读过滤链,于是两页 42703(冒烟抓到,类型系统看不见)。行谓词 processing.view OR finance.view。';

COMMIT;

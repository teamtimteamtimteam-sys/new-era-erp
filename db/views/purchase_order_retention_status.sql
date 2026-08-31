-- db/views/purchase_order_retention_status.sql
-- EQP-PAY-1:每一条质保金【现在】处在什么状态。
--
-- ★【maturity_date 是算出来的,不是存下来的】★ fixed_assets.acceptance_date 一改,
-- 它当场跟着走。存一个字面量,等于在验收推迟的那一刻【悄悄地错】,而没有人会发现
-- (db/fixtures/177 的 C 臂断言的正是这个差值,一份把它存成列的实现在那里变红)。
--
-- 【四态】
--   clock_not_started —— 还没验收。**不是错误,不是零**,今天对线上两台机器都为真。
--   running           —— 质保期内。
--   awaiting_confirmation —— 到期了,【等人确认】。**应付尚未成立** —— 到期不自动付。
--   released          —— 有人确认过了。
--
-- 【属主权限的理由(OPS-14 那一族)】体内 JOIN 了 fixed_assets,而那张表要
-- module.finance.view。一个只有采购权限的读者会让 INNER JOIN 【整行消失】,于是
-- "这台机器有没有质保金"对不同的人给出不同的答案,而且不出声。借来的列是
-- 【推导事实】(一个日期、一个状态词)→ 补救 (a):属主权限 + 把读者自己的模块
-- 谓词原样写回视图体。金额那几列是【钱】→ 补救 (b):按 data.view_prices 遮成 NULL。
--
-- NOTE: introduced by db/migrations/2026-09-01-eqppay1-b-equipment-milestones-and-retention.sql.

CREATE VIEW public.purchase_order_retention_status WITH (security_invoker = off) AS
 SELECT r.id AS retention_id,
    r.purchase_order_line_id,
    pol.purchase_order_id,
    po.code AS purchase_order_code,
    po.currency,
    pol.line_no,
    fa.id AS asset_id,
    fa.code AS asset_code,
    fa.description AS asset_description,
    fa.acceptance_date,
    r.anchor_event,
    r.retention_months,
        CASE
            WHEN fa.acceptance_date IS NULL THEN NULL::date
            ELSE (fa.acceptance_date + ((r.retention_months || ' months'::text)::interval))::date
        END AS maturity_date,
        CASE
            WHEN fa.acceptance_date IS NULL THEN 'clock_not_started'::text
            WHEN r.released_at IS NOT NULL THEN 'released'::text
            WHEN (fa.acceptance_date + ((r.retention_months || ' months'::text)::interval))::date <= CURRENT_DATE THEN 'awaiting_confirmation'::text
            ELSE 'running'::text
        END AS retention_state,
    r.percentage,
        CASE
            WHEN has_permission('data.view_prices'::text) THEN r.fixed_amount_ccy
            ELSE NULL::numeric
        END AS fixed_amount_ccy,
        CASE
            WHEN has_permission('data.view_prices'::text) THEN COALESCE(r.fixed_amount_ccy, round(pol.estimated_amount_ccy * r.percentage / 100.0, 2))
            ELSE NULL::numeric
        END AS retention_amount_ccy,
    r.released_at,
    r.released_by,
        CASE
            WHEN has_permission('data.view_prices'::text) THEN r.released_amount_ccy
            ELSE NULL::numeric
        END AS released_amount_ccy,
        CASE
            WHEN has_permission('data.view_prices'::text) THEN r.withheld_amount_ccy
            ELSE NULL::numeric
        END AS withheld_amount_ccy,
    r.withholding_reason
   FROM purchase_order_line_retentions r
     JOIN purchase_order_lines pol ON pol.id = r.purchase_order_line_id
     JOIN purchase_orders po ON po.id = pol.purchase_order_id
     JOIN fixed_assets fa ON fa.id = pol.asset_id
  WHERE has_permission('module.purchasing.view'::text);

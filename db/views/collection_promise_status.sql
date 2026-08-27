-- db/views/collection_promise_status.sql
-- CHASE-1：每个承诺一行 —— 它是什么、逾期了没有、它那条催收还活着没有。
--
-- ★【逾期就在承诺日【当天】(`<=`)】★ —— Tim 2026-08-28 裁定，CHASE-1-FU 改的。
-- CHASE-1 落地时是 `<`（第二天起算）；这是一次**被决定改掉的边界，不是漂移**。
-- 理由是一件关于这门生意的事实：**货款通常在下午中段到账**，所以承诺日当天
-- 有人来看这张单子时，一笔还没到的款已经是那天要处理的那件事；推到第二天，
-- 单子就恰好在它最有用的那一天保持沉默。**不要把这个 `<=` 改回 `<`。**
--
-- ★【WITH (security_invoker = off) 是手工补回来的】★
-- `pg_get_viewdef()` 只吐 SELECT，**不吐 reloptions**（AGENTS.md 为此记过一次）。
-- 照它重建镜像会把这一句悄悄丢掉：行为上不变（PostgreSQL 默认就是属主权限），
-- 红的是【镜像文本】那一栏 —— 而下一个读镜像的人正是据此判断这张视图是不是
-- 【刻意】声明过属主权限的。这里是刻意的（OPS-14 修法 (a)）。
--
-- ★【COMMENT ON VIEW 也是手工带上的】★ 同一个理由的另一半：`pg_get_viewdef()`
-- 不吐对象注释，而 CHASE-1 的镜像因此【漏了它】—— 一份重建出来的库会少掉
-- 这张视图上所有的来由。CHASE-1-FU 补上，与表镜像的 COMMENT ON TABLE 一致。
--
-- NOTE: introduced by db/migrations/2026-08-27-chase1-collection-records.sql,
--       boundary corrected by db/migrations/2026-08-28-chase1-fu2-overdue-on-the-promised-date.sql.

CREATE VIEW public.collection_promise_status WITH (security_invoker = off) AS
SELECT pr.id AS promise_id,
    ch.id AS chase_id,
    ch.code AS chase_code,
    ch.customer_id,
    cu.code AS customer_code,
    cu.legal_name AS customer_name,
    ch.chased_on,
    ch.channel,
    pr.promised_amount_ccy,
    pr.currency,
    pr.promised_amount_base,
    pr.promised_date,
    pr.outcome,
    pr.outcome_recorded_at,
    pr.outcome IS NULL AND ch.superseded_at IS NULL AND pr.promised_date <= CURRENT_DATE AS is_overdue,
    pr.outcome IS NULL AND ch.superseded_at IS NULL AS is_open,
    ch.superseded_at IS NOT NULL AS chase_superseded,
    ch.superseded_reason
   FROM collection_promises pr
     JOIN collection_chases ch ON ch.id = pr.chase_id
     JOIN customers cu ON cu.id = ch.customer_id;

COMMENT ON VIEW public.collection_promise_status IS
    'CHASE-1：每个承诺一行 —— 它是什么、逾期了没有、它那条催收还活着没有。★【逾期就在承诺日【当天】(`<=`)】★ —— Tim 2026-08-28 裁定，fu2 改的。理由是一件关于这门生意的事实：**货款通常在下午中段到账**，所以承诺日当天有人来看这张单子时，一笔还没到的款已经是那天要处理的那件事；推到第二天，单子就恰好在它最有用的那一天保持沉默。**不要把这个 `<=` 改回 `<`** —— 它不是差一天的笔误。仍然不设宽限期：一个没人调的旋钮会让「逾期」在不同时候意思不同。【这条边界全库只有这一处】customer_collection_context 原先又算了一遍同样的比较，fu2 把它改成读这张视图 —— 一条写在两个地方的规矩迟早会在两个地方不一致。属主权限（security_invoker = off）：它横跨 finance 与 customers，invoker 会让 RLS 把读者无权的那一侧静默丢掉，而行消失在这里意味着「少了一个逾期承诺」而不是报错（OPS-14 修法 (a)）。★【它刻意只有纯 SQL，一个函数都不调】★ ① 属主权限替不了函数的 EXECUTE，而 customer_statement_data 里有 require_permission —— 放进这张要喂 operations_now 的视图会让没有 finance 权限的读者整个仪表盘报错；② 它每行要跑两次 ar_aging_asof，那是对账页的活，不上人人都开的首页。';

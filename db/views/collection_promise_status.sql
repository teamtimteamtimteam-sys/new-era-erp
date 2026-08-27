-- db/views/collection_promise_status.sql
-- CHASE-1：每个承诺一行 —— 它是什么、逾期了没有、它那条催收还活着没有。
--
-- ★【WITH (security_invoker = off) 是手工补回来的】★
-- `pg_get_viewdef()` 只吐 SELECT，**不吐 reloptions**（AGENTS.md 为此记过一次）。
-- 照它重建镜像会把这一句悄悄丢掉：行为上不变（PostgreSQL 默认就是属主权限），
-- 红的是【镜像文本】那一栏 —— 而下一个读镜像的人正是据此判断
-- 这张视图是不是【刻意】声明过属主权限的。这里是刻意的：它横跨 finance 与
-- customers，invoker 会让 RLS 把读者无权的那一侧静默丢掉，而行消失在这里
-- 意味着"少了一个逾期承诺"，不是报错（OPS-14 修法 (a)）。
--
-- 【它刻意只有纯 SQL，一个函数都不调】两个理由都是实测出来的，写在
-- db/migrations/2026-08-27-chase1-collection-records.sql 与表注释里，不复述。
--
-- NOTE: introduced by db/migrations/2026-08-27-chase1-collection-records.sql.

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
    pr.outcome IS NULL AND ch.superseded_at IS NULL AND pr.promised_date < CURRENT_DATE AS is_overdue,
    pr.outcome IS NULL AND ch.superseded_at IS NULL AS is_open,
    ch.superseded_at IS NOT NULL AS chase_superseded,
    ch.superseded_reason
   FROM collection_promises pr
     JOIN collection_chases ch ON ch.id = pr.chase_id
     JOIN customers cu ON cu.id = ch.customer_id;

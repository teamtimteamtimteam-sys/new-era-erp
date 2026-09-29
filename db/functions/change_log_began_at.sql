-- db/functions/change_log_began_at.sql
-- AUDIT-TRAIL-1a(Tim 的 Q1):变更记录【开始记】的那一刻 —— 线上 change_log 第 1 行的 occurred_at
--   (HISTORY-1 迁移自己那一笔,2026-09-28 23:58:11 新加坡时间;量法:SELECT min(occurred_at) FROM change_log,以 postgres 读)。
-- 早于它的历史只能从领域历史表与生命周期戳里拼回来(record_trail 的"记录开始之前"那一段,分界线之下);
-- 晚于它的一切都在 change_log 里。它是【声明的】,不是推出来的 —— 推出来的线会在有人补录一行旧数据的那一刻悄悄移动
-- (与 finance_settings.system_start_date 同一条理由,见 AGENTS.md「Entitlement is DERIVED」)。
CREATE OR REPLACE FUNCTION public.change_log_began_at()
 RETURNS timestamp with time zone
 LANGUAGE sql
 IMMUTABLE
 SET search_path TO 'public', 'pg_temp'
AS $function$
    SELECT '2026-09-28 23:58:11.294246+08'::timestamptz;
$function$;

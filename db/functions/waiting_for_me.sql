-- db/functions/waiting_for_me.sql
-- SYSTEM-MAP-2(Tim 2026-10-26 裁定 2.4 (9) · (10)):★【工作台 › 待办】的唯一一份数据 —— 在等【读者】动手的每一件事,一张清单★
--   decision      waiting_decisions():我批得了的每一种审批,以及已批准、等我付的付款申请
--   mine          waiting_mine():我的任务 · 我要写的考核 · 我要做的自评
--   notification  我没读过的通知(按读者自己的读策略:notifications 的 RLS 与 notification_reads 的 select own —— 本函数是
--                 SECURITY INVOKER,所以"谁看得见哪条通知"不在这里另写一遍)
-- 两个读者:/workbench(待办页)与首页那一个数(waiting_for_me_count)—— 规矩只有这一份(Tim 2.4 (10))。
-- 提醒页的审批支读的是 waiting_decisions(经 operations_now),与本函数的 decision 那一段是同一支。
--
-- NOTE: introduced by db/migrations/2026-10-27-system-map-2-my-workbench.sql.

CREATE OR REPLACE FUNCTION public.waiting_for_me()
 RETURNS TABLE(kind text, item_type text, item_id uuid, parent_id uuid, doc_kind text, code text, subject text, raised_by jsonb, waiting_since timestamp with time zone, due_date date)
 LANGUAGE sql
 STABLE
 SET search_path TO 'public', 'pg_temp'
AS $function$
    SELECT 'decision'::text, d.item_type, d.item_id, d.parent_id, d.doc_kind, d.code, d.subject, d.raised_by, d.waiting_since, NULL::date
      FROM waiting_decisions() d
    UNION ALL
    SELECT 'mine', m.item_type, m.item_id, m.parent_id, m.doc_kind, m.code, m.subject, m.raised_by, m.waiting_since, m.due_date
      FROM waiting_mine() m
    UNION ALL
    SELECT 'notification', 'notification', n.id, n.subject_id, n.subject_type, n.subject_code, n.event_type,
           jsonb_build_object('state', 'system'), n.occurred_at, NULL::date
      FROM notifications n
     WHERE auth.uid() IS NOT NULL
       AND NOT EXISTS (SELECT 1 FROM notification_reads r WHERE r.notification_id = n.id AND r.user_id = auth.uid())
$function$;

COMMENT ON FUNCTION public.waiting_for_me() IS
'SYSTEM-MAP-2:工作台 › 待办的唯一一份数据 —— 我批得了的审批与等我付的付款(waiting_decisions)· 我的任务与考核(waiting_mine)· 我没读过的通知(SECURITY INVOKER:通知按读者自己的 RLS 读)。两个读者:/workbench 与首页的待办数(waiting_for_me_count)。';

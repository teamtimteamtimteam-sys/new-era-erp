-- db/functions/warehouse_requests_visible.sql
-- APR-7(2026-09-25,grilling Q8):库存页上那一块读的就是这里 —— 仓库看得见自己提的申请,CFO 看得见要他批的。
--   谁读得到:持 module.inventory.view 的人(库存页的门;cfo 与 warehouse 都持)。其余 → 零行。
--   【金额按 data.view_prices 给】没有它的读者(仓库)amount_base 是 NULL —— 注销的价值是一个价格。
--   只给在等的全部 + 最近决定 / 撤回的 p_recent 张;raised_by_me = 提单人就是读者这个人(按人认)。
--   提单人 / 决定人的邮箱给屏幕读"谁提的、谁批的"。
-- NOTE: introduced by db/migrations/2026-09-25-apr7-write-offs-rollbacks-and-cod-voids-wait-for-the-cfo.sql.

CREATE OR REPLACE FUNCTION public.warehouse_requests_visible(p_recent integer DEFAULT 10)
 RETURNS TABLE(id uuid, kind text, status text, label text, inbound_batch_id uuid, output_batch_id uuid, run_id uuid, cod_id uuid, reason text, snapshot jsonb, amount_base numeric, created_at timestamptz, created_by_email text, raised_by_me boolean, decided_at timestamptz, decided_by_email text, decision_notes text, withdrawn_at timestamptz, withdraw_reason text)
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
    WITH r AS (
        SELECT q.*, (q.status = 'submitted') AS is_open,
               row_number() OVER (PARTITION BY (q.status = 'submitted')
                                  ORDER BY COALESCE(q.decided_at, q.withdrawn_at, q.created_at) DESC) AS rn
          FROM warehouse_requests q
         WHERE has_permission('module.inventory.view'))
    SELECT r.id, r.kind, r.status, r.label, r.inbound_batch_id, r.output_batch_id, r.run_id, r.cod_id,
           r.reason, r.snapshot,
           CASE WHEN has_permission('data.view_prices') THEN r.amount_base END,
           r.created_at,
           (SELECT u.email::text FROM auth.users u WHERE u.id = r.created_by),
           self_leg(r.created_by, NULL, auth.uid()) = 'raiser',
           r.decided_at,
           (SELECT u.email::text FROM auth.users u WHERE u.id = r.decided_by),
           r.decision_notes, r.withdrawn_at, r.withdraw_reason
      FROM r
     WHERE r.is_open OR r.rn <= GREATEST(COALESCE(p_recent, 10), 0)
     ORDER BY r.is_open DESC, COALESCE(r.decided_at, r.withdrawn_at, r.created_at) DESC
$function$;

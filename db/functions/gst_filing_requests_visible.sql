-- db/functions/gst_filing_requests_visible.sql
-- APR-10(2026-09-27):GST 期间页上"申报申请"那一块读的就是这里 —— 财务看得见自己提的,CFO 看得见要他批的。
--   谁读得到:module.finance.view(GST 页的门)。其余 → 零行。
--   p_period_id 给了就只给那一期的;只给在等的全部 + 最近决定 / 撤回的 p_recent 张。
--   boxes = 提交时冻结的那一组;current_boxes = 此刻再算一遍(只对在等的算 —— 决定了的不必);
--   current_matches = 两者逐字相等(不相等,批准会被 GST_RETURN_CHANGED_SINCE_REQUEST 拒,屏幕先说出来)。
--   original_code / original_boxes:这一期是一份更正件(F7)时,被更正的那一份与它【报出去的】快照 ——
--   CFO 逐格看见差(grilling Q2)。raised_by_me = 提单人就是读者这个人(按人认)。
-- NOTE: introduced by db/migrations/2026-09-27-apr10-gst-filing-and-po-categories.sql.

CREATE OR REPLACE FUNCTION public.gst_filing_requests_visible(p_period_id uuid DEFAULT NULL::uuid, p_recent integer DEFAULT 10)
 RETURNS TABLE(id uuid, status text, label text, period_id uuid, period_code text, period_start date, period_end date, boxes jsonb, current_boxes jsonb, current_matches boolean, original_code text, original_boxes jsonb, note text, created_at timestamptz, created_by_email text, raised_by_me boolean, decided_at timestamptz, decided_by_email text, decision_notes text, withdrawn_at timestamptz, withdraw_reason text)
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
    WITH r AS (
        SELECT q.*, (q.status = 'submitted') AS is_open,
               row_number() OVER (PARTITION BY (q.status = 'submitted')
                                  ORDER BY COALESCE(q.decided_at, q.withdrawn_at, q.created_at) DESC) AS rn
          FROM gst_filing_requests q
         WHERE has_permission('module.finance.view')
           AND (p_period_id IS NULL OR q.period_id = p_period_id)),
    c AS (
        SELECT r.id, CASE WHEN r.is_open THEN f5_return(p.period_start, p.period_end)->'boxes' END AS now_boxes
          FROM r JOIN gst_periods p ON p.id = r.period_id)
    SELECT r.id, r.status, r.label, r.period_id, p.code, p.period_start, p.period_end,
           r.boxes, c.now_boxes,
           CASE WHEN r.is_open THEN c.now_boxes IS NOT DISTINCT FROM r.boxes END,
           o.code,
           (SELECT jsonb_agg(jsonb_build_object('box', b.box, 'value', b.value_base) ORDER BY b.box)
              FROM gst_return_boxes b WHERE b.period_id = o.id),
           r.note, r.created_at,
           (SELECT u.email::text FROM auth.users u WHERE u.id = r.created_by),
           self_leg(r.created_by, NULL, auth.uid()) = 'raiser',
           r.decided_at,
           (SELECT u.email::text FROM auth.users u WHERE u.id = r.decided_by),
           r.decision_notes, r.withdrawn_at, r.withdraw_reason
      FROM r
      JOIN c ON c.id = r.id
      JOIN gst_periods p ON p.id = r.period_id
      LEFT JOIN gst_periods o ON o.id = p.corrects_period_id
     WHERE r.is_open OR r.rn <= GREATEST(COALESCE(p_recent, 10), 0)
     ORDER BY r.is_open DESC, COALESCE(r.decided_at, r.withdrawn_at, r.created_at) DESC
$function$;

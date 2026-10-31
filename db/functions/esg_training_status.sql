-- db/functions/esg_training_status.sql
-- ESG-2(Tim 2026-10-31 Q8):【谁的哪一门必修培训是什么状态】—— 每一门在用的必修培训 × 每一位它适用的在职员工,一行。
--   适用:everyone 全体 · office / shopfloor 按 employees.work_category · positions 按 employees.position_id ∈ position_ids;
--     在职 = 没有软删、employment_status 不是 separated。
--   这一位的那一门取【最好的一条】挂着它的培训记录(没删的):到期日 = 记录自己的 expiry_date,没写而这一门有有效期 → completed_date + 有效期,
--     两样都没有 → 不过期(最好);有到期日的取最晚的那一条。
--   status:valid(不过期,或 90 天以外)· expiring(90 天内到期;days_remaining ≤ 30 页面标紧急 —— 与 hr_alerts 同一组窗口)·
--     expired(已过期)· missing(一条挂着它的记录都没有)。今天 = 新加坡的今天。
--   【门】module.hr.view(培训记录的读码);不持 → 按名拒。【一份实现,两个读者】培训合规页的人表与 esg_training_coverage 的合计。
-- NOTE: introduced by db/migrations/2026-10-31-esg-2.sql.
CREATE OR REPLACE FUNCTION public.esg_training_status()
 RETURNS TABLE(required_training_id uuid, training_name text, employee_id uuid, employee_code text, employee_name text, status text, training_record_id uuid, completed_date date, expiry_date date, days_remaining integer)
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
#variable_conflict use_column
DECLARE
    v_today date := (now() AT TIME ZONE 'Asia/Singapore')::date;
BEGIN
    PERFORM require_permission('module.hr.view');
    RETURN QUERY
    WITH rt AS (
        SELECT t.* FROM required_trainings t WHERE t.retired_at IS NULL
    ), who AS (
        SELECT rt.id AS rt_id, rt.name AS rt_name, rt.validity_months, e.id AS e_id, e.code AS e_code,
               COALESCE(e.preferred_name, e.legal_name) AS e_name
          FROM rt
          JOIN employees e ON e.deleted_at IS NULL AND e.employment_status <> 'separated'
         WHERE rt.applies_to = 'everyone'
            OR (rt.applies_to IN ('office', 'shopfloor') AND e.work_category = rt.applies_to)
            OR (rt.applies_to = 'positions' AND e.position_id = ANY (rt.position_ids))
    ), best AS (
        SELECT DISTINCT ON (w.rt_id, w.e_id) w.rt_id, w.e_id, r.id AS rec_id, r.completed_date,
               COALESCE(r.expiry_date, CASE WHEN w.validity_months IS NOT NULL
                                            THEN (r.completed_date + make_interval(months => w.validity_months))::date END) AS exp
          FROM who w
          JOIN training_records r ON r.employee_id = w.e_id AND r.required_training_id = w.rt_id AND r.deleted_at IS NULL
         ORDER BY w.rt_id, w.e_id,
                  (COALESCE(r.expiry_date, CASE WHEN w.validity_months IS NOT NULL
                                                THEN (r.completed_date + make_interval(months => w.validity_months))::date END)) DESC NULLS FIRST,
                  r.completed_date DESC, r.id
    )
    SELECT w.rt_id, w.rt_name, w.e_id, w.e_code, w.e_name,
           CASE WHEN b.rec_id IS NULL THEN 'missing'
                WHEN b.exp IS NULL THEN 'valid'
                WHEN b.exp < v_today THEN 'expired'
                WHEN b.exp - v_today <= 90 THEN 'expiring'
                ELSE 'valid' END AS status,
           b.rec_id, b.completed_date, b.exp,
           CASE WHEN b.exp IS NULL THEN NULL ELSE (b.exp - v_today) END
      FROM who w
      LEFT JOIN best b ON b.rt_id = w.rt_id AND b.e_id = w.e_id
     ORDER BY w.rt_name, w.e_code;
END;
$function$;

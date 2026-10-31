-- db/functions/esg_training_coverage.sql
-- ESG-2(Tim 2026-10-31 Q8):每一门在用的必修培训的覆盖 —— 适用几人、有效几人(含快到期)、快到期几人、已过期几人、没有记录几人。
--   覆盖率 = (有效 + 快到期)÷ 适用(快到期仍然有效)。逐人的判定只在 esg_training_status 里(这里只是数它),门也由它判(module.hr.view)。
--   门自己先判一次(module.hr.view,不持 → 按名拒),不靠被读的那一支恰好被求值。
--   一门一个适用的人都没有 → applicable 0,页面说「没有适用的在职员工」,不画一个 0%。
-- NOTE: introduced by db/migrations/2026-10-31-esg-2.sql.
CREATE OR REPLACE FUNCTION public.esg_training_coverage()
 RETURNS TABLE(required_training_id uuid, name text, category text, validity_months integer, applies_to text, position_ids uuid[], applicable integer, valid integer, expiring integer, expired integer, missing integer)
 LANGUAGE plpgsql
 STABLE
 SET search_path TO 'public', 'pg_temp'
AS $function$
#variable_conflict use_column
BEGIN
    PERFORM require_permission('module.hr.view');
    RETURN QUERY
    WITH s AS (SELECT * FROM esg_training_status())
    SELECT t.id, t.name, t.category, t.validity_months, t.applies_to, t.position_ids,
           count(s.employee_id)::integer,
           count(*) FILTER (WHERE s.status = 'valid')::integer,
           count(*) FILTER (WHERE s.status = 'expiring')::integer,
           count(*) FILTER (WHERE s.status = 'expired')::integer,
           count(*) FILTER (WHERE s.status = 'missing')::integer
      FROM required_trainings t
      LEFT JOIN s ON s.required_training_id = t.id
     WHERE t.retired_at IS NULL
     GROUP BY t.id
     ORDER BY t.name;
END;
$function$;

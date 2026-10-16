-- db/views/inspection_template_rows.sql
-- MES-7b-2(2026-10-16,MES-7b Step 0 Q13 · Q17 · Q20,Tim):巡检清单那一页的一行 —— 清单的列、检查项的数目、最近一次巡检与到期
--   (inspection_template_due_all,一份实现)。【属主权限】门 module.safety.view(与清单表的读策略同一个码),条件写在末尾的 WHERE 里一次。
--
-- NOTE: introduced by db/migrations/2026-10-16-mes7b2-inspections-and-environment.sql.

CREATE VIEW public.inspection_template_rows WITH (security_invoker = off) AS
 SELECT t.id,
    t.code,
    t.name,
    t.area,
    t.frequency_days,
    t.is_active,
    t.notes,
    t.created_at,
    t.updated_at,
    ( SELECT count(*)::integer AS count
           FROM inspection_template_items i
          WHERE i.template_id = t.id) AS item_count,
    ( SELECT count(*)::integer AS count
           FROM inspection_runs r
          WHERE r.template_id = t.id) AS run_count,
    d.last_run_id,
    d.last_run_code,
    d.last_inspected_at,
    d.next_due_on,
    d.due_state
   FROM inspection_templates t
     JOIN inspection_template_due_all d ON d.id = t.id
  WHERE has_permission('module.safety.view'::text);

COMMENT ON VIEW public.inspection_template_rows IS
    'MES-7b-2:巡检清单那一页的一行 —— 清单、检查项数、巡过几次、最近一次没被更正过的巡检、下一次到期(V18 频率)与到期的状态。属主权限,门 module.safety.view。';

-- ★ 属主视图可以被写穿(以属主身份写基表):先全收,再只授回 SELECT(F16)。
REVOKE ALL ON public.inspection_template_rows FROM authenticated, anon;
GRANT SELECT ON public.inspection_template_rows TO authenticated;

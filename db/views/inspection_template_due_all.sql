-- db/views/inspection_template_due_all.sql
-- MES-7b-2(2026-10-16,MES-7b Step 0 Q13 · Q20,Tim):【一张巡检清单该不该巡了】—— 每一张清单最近一次(没有被更正过的)巡检,
--   以及按它的频率(V18)算出来的下一次到期日。【一份实现,两个读者】:清单页(inspection_template_rows)与提醒 inspection_due(operations_now)。
--   ★ 底视图:不授给 authenticated(只由属主视图读)—— 它不带读者的谓词。
--   due_state:not_set(频率空着 —— V18 Not yet set,没有日子可数)· never_run(有频率、还没巡过)· due(上一次巡检的日子 + 频率 ≤ 今天)·
--     not_due。日子按新加坡。被更正过的那一次不算"最近一次" —— 更正它的那一次替它说话。
--
-- NOTE: introduced by db/migrations/2026-10-16-mes7b2-inspections-and-environment.sql.

CREATE VIEW public.inspection_template_due_all WITH (security_invoker = off) AS
 SELECT t.id,
    t.frequency_days,
    lr.id AS last_run_id,
    lr.code AS last_run_code,
    lr.inspected_at AS last_inspected_at,
    (lr.inspected_at AT TIME ZONE 'Asia/Singapore'::text)::date AS last_inspected_on,
    (lr.inspected_at AT TIME ZONE 'Asia/Singapore'::text)::date + t.frequency_days AS next_due_on,
        CASE
            WHEN t.frequency_days IS NULL THEN 'not_set'::text
            WHEN lr.id IS NULL THEN 'never_run'::text
            WHEN ((lr.inspected_at AT TIME ZONE 'Asia/Singapore'::text)::date + t.frequency_days) <= (now() AT TIME ZONE 'Asia/Singapore'::text)::date THEN 'due'::text
            ELSE 'not_due'::text
        END AS due_state
   FROM inspection_templates t
     LEFT JOIN LATERAL ( SELECT r.id,
            r.code,
            r.inspected_at
           FROM inspection_runs r
          WHERE r.template_id = t.id AND NOT (EXISTS ( SELECT 1
                   FROM inspection_runs c
                  WHERE c.corrects_run_id = r.id))
          ORDER BY r.inspected_at DESC, r.code DESC
         LIMIT 1) lr ON true;

COMMENT ON VIEW public.inspection_template_due_all IS
    'MES-7b-2:每一张巡检清单最近一次没被更正过的巡检与下一次到期日(频率 V18;due_state not_set · never_run · due · not_due,新加坡日子)。底视图,不授给 authenticated —— 清单页与提醒 inspection_due 共用这一份。';

REVOKE ALL ON public.inspection_template_due_all FROM authenticated, anon;

-- db/views/incident_rows.sql
-- MES-7b-1(2026-10-16,MES-7b Step 0 Q3 · Q6 · Q10 · Q11 · Q17,Tim):事故清单与事故页读的那一行 —— 现在的值(incident_current_all)
--   加上人读的标签(种类的名字、库位、机器、负责的人、引用的停机与异常事件)与受伤的细节(经 incidents_masked,遮蔽照旧)。
--   【属主权限】行谓词就是 incidents_masked 的那一句(module.safety.view,或受伤的那名员工本人):它读 incidents_masked,
--   而那张视图里的 has_permission / current_user_employee 回答的是【调用者】(AGENTS.md:属主视图不放宽模块的门)。
--   借来的列只有【标签】(名字、编号、时刻)—— 显示标签跟着单据走(四条常设裁定之三),没有任何一列钱。
--   injury_visible:这位读者能不能读受伤的细节(data.view_health 或本人)。为假时页面说「受限」—— 不论这一件有没有受伤的记录,
--   于是"有没有人受伤"这件事本身也不会从一个空字段里漏出去。
--
-- NOTE: introduced by db/migrations/2026-10-16-mes7b1-incidents.sql.

CREATE VIEW public.incident_rows WITH (security_invoker = off) AS
 SELECT m.id,
    m.code,
    c.kind_code,
    k.name_en AS kind_name_en,
    k.name_zh AS kind_name_zh,
    c.occurred_at,
    c.occurred_on,
    m.location_id,
    l.code AS location_code,
    l.name AS location_name,
    m.equipment_id,
    fa.code AS equipment_code,
    fa.description AS equipment_name,
    c.duration_min,
    c.what_happened,
    c.immediate_action,
    c.responsible_employee_id,
    COALESCE((re.code || ' · '::text) || COALESCE(re.preferred_name, re.legal_name), c.responsible_name) AS responsible_label,
    c.nea_reportable,
    m.source,
    m.downtime_id,
    d.started_at AS downtime_started_at,
    m.run_event_id,
    ev.run_id AS run_event_run_id,
    pr.code AS run_event_run_code,
    ev.event_type_code AS run_event_type,
    ev.occurred_at AS run_event_occurred_at,
    m.recorded_at,
    m.recorded_by,
    c.corrections,
    c.notified_at,
    c.notified_reference,
    c.report_submitted_at,
    c.report_reference,
    c.closed_at,
    c.closed_summary,
    c.report_deadline,
    c.deadline_state,
    c.deadline_working_days,
    c.deadline_confirmed,
    has_permission('data.view_health'::text) OR COALESCE(m.injured_employee_id = current_user_employee(), false) AS injury_visible,
    m.injured_employee_id,
    (ie.code || ' · '::text) || COALESCE(ie.preferred_name, ie.legal_name) AS injured_employee_label,
    m.injured_person_name,
    m.injury_nature,
    m.injury_treatment,
    m.days_lost,
    ( SELECT count(*)::integer AS count
           FROM incident_batches b
          WHERE b.incident_id = m.id AND b.unlinked_at IS NULL) AS linked_batches
   FROM incidents_masked m
     JOIN incident_current_all c ON c.id = m.id
     JOIN incident_kinds k ON k.code = c.kind_code
     LEFT JOIN storage_locations l ON l.id = m.location_id
     LEFT JOIN fixed_assets fa ON fa.id = m.equipment_id
     LEFT JOIN employees re ON re.id = c.responsible_employee_id
     LEFT JOIN employees ie ON ie.id = m.injured_employee_id
     LEFT JOIN equipment_downtime d ON d.id = m.downtime_id
     LEFT JOIN processing_run_events ev ON ev.id = m.run_event_id
     LEFT JOIN processing_runs pr ON pr.id = ev.run_id;

COMMENT ON VIEW public.incident_rows IS
    'MES-7b-1:事故清单与事故页的一行 —— 现在的值(更正过的)、NEA 通报 / 书面报告 / 关闭、期限与它的状态(未确认的 V19 照算、标出来)、人读的标签,以及受伤的细节(经 incidents_masked 遮蔽;injury_visible 为假时页面说「受限」)。属主权限,行谓词 = incidents_masked 的那一句(module.safety.view 或本人)。';

-- ★ 默认权限会把 INSERT / UPDATE / DELETE 也授给 authenticated(线上 pg_default_acl:postgres 建的表与视图 authenticated=arwdDxtm),
--   而一张简单的属主视图是【可以写穿的】—— 以属主身份写基表,绕开 RLS 与那几支 DEFINER 函数的码。所以先全收,再只授回 SELECT。
REVOKE ALL ON public.incident_rows FROM authenticated, anon;
GRANT SELECT ON public.incident_rows TO authenticated;

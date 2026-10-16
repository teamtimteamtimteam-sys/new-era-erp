-- db/views/incident_current_all.sql
-- MES-7b-1(2026-10-16,MES-7b Step 0 Q3 · Q10 · Q11,Tim):【一件事故现在是什么样】—— 那一行(写下就不改)加上它的更正与之后的事实,
--   以及 NEA 书面报告的期限。【一份实现,四个读者】:事故页与清单(incident_rows)、两条提醒(operations_now 的 incident_nea_notify_due ·
--   incident_report_due)、批次的建议(suggest_incident_batches 用更正过的时刻)、更新函数(record_incident_update 判"与现在的值相同")。
--   ★ 底视图:不授给 authenticated(只由属主视图与 DEFINER 函数读)—— 它不带受伤的细节,但也不带读者的谓词。
--
--   【更正】每个字段取【最后一次】更正(id 最大 —— identity 记录先后;同一笔事务里的两行 recorded_at 一样,排不出先后,AGING-1)。
--     负责的人被更正成一个名字之后,原来指的那名员工不再算数(responsible_employee_id 读成空)。
--   【期限】(Q10 · Q11)只对现在要通报的事故算:report_deadline = business_days_after(事故的新加坡日期, V19)。
--     deadline_state:not_reportable(不用通报)· submitted(书面报告交了)· not_set(V19 是空的)· cannot_compute(数到的那几年里
--     有一年公共假期表是空的 —— 不猜日子)· computed。deadline_confirmed = V19 有没有被对着执照确认过(引导值没有,于是期限标"未确认")。
--
-- NOTE: introduced by db/migrations/2026-10-16-mes7b1-incidents.sql.

CREATE VIEW public.incident_current_all WITH (security_invoker = off) AS
 SELECT x.id,
    x.code,
    x.kind_code,
    x.occurred_at,
    (x.occurred_at AT TIME ZONE 'Asia/Singapore'::text)::date AS occurred_on,
    x.location_id,
    x.equipment_id,
    x.duration_min,
    x.what_happened,
    x.immediate_action,
    x.responsible_employee_id,
    x.responsible_name,
    x.nea_reportable,
    x.source,
    x.downtime_id,
    x.run_event_id,
    x.recorded_at,
    x.recorded_by,
    x.corrections,
    x.notified_at,
    x.notified_reference,
    x.report_submitted_at,
    x.report_reference,
    x.closed_at,
    x.closed_summary,
        CASE
            WHEN x.nea_reportable THEN business_days_after((x.occurred_at AT TIME ZONE 'Asia/Singapore'::text)::date, s.nea_report_working_days)
            ELSE NULL::date
        END AS report_deadline,
        CASE
            WHEN NOT x.nea_reportable THEN 'not_reportable'::text
            WHEN x.report_submitted_at IS NOT NULL THEN 'submitted'::text
            WHEN s.nea_report_working_days IS NULL THEN 'not_set'::text
            WHEN business_days_after((x.occurred_at AT TIME ZONE 'Asia/Singapore'::text)::date, s.nea_report_working_days) IS NULL THEN 'cannot_compute'::text
            ELSE 'computed'::text
        END AS deadline_state,
    s.nea_report_working_days AS deadline_working_days,
    s.nea_report_days_confirmed_at IS NOT NULL AS deadline_confirmed
   FROM ( SELECT i.id,
            i.code,
            COALESCE(c_kind.v, i.kind_code) AS kind_code,
            COALESCE(c_time.v::timestamptz, i.occurred_at) AS occurred_at,
            i.location_id,
            i.equipment_id,
            COALESCE(c_dur.v::numeric, i.duration_min) AS duration_min,
            COALESCE(c_what.v, i.what_happened) AS what_happened,
            COALESCE(c_act.v, i.immediate_action) AS immediate_action,
                CASE
                    WHEN c_resp.v IS NOT NULL THEN NULL::uuid
                    ELSE i.responsible_employee_id
                END AS responsible_employee_id,
            COALESCE(c_resp.v, i.responsible_name) AS responsible_name,
            COALESCE(c_nea.v::boolean, i.nea_reportable) AS nea_reportable,
            i.source,
            i.downtime_id,
            i.run_event_id,
            i.recorded_at,
            i.recorded_by,
            ( SELECT count(*)::integer AS count
                   FROM incident_updates u
                  WHERE u.incident_id = i.id AND u.kind = 'correction'::text) AS corrections,
            n.occurred_at AS notified_at,
            n.reference AS notified_reference,
            r.occurred_at AS report_submitted_at,
            r.reference AS report_reference,
            cl.recorded_at AS closed_at,
            cl.summary AS closed_summary
           FROM incidents i
             LEFT JOIN incident_updates n ON n.incident_id = i.id AND n.kind = 'nea_notified'::text
             LEFT JOIN incident_updates r ON r.incident_id = i.id AND r.kind = 'report_submitted'::text
             LEFT JOIN incident_updates cl ON cl.incident_id = i.id AND cl.kind = 'closed'::text
             LEFT JOIN LATERAL ( SELECT u.new_value AS v
                   FROM incident_updates u
                  WHERE u.incident_id = i.id AND u.kind = 'correction'::text AND u.field = 'kind_code'::text
                  ORDER BY u.id DESC
                 LIMIT 1) c_kind ON true
             LEFT JOIN LATERAL ( SELECT u.new_value AS v
                   FROM incident_updates u
                  WHERE u.incident_id = i.id AND u.kind = 'correction'::text AND u.field = 'occurred_at'::text
                  ORDER BY u.id DESC
                 LIMIT 1) c_time ON true
             LEFT JOIN LATERAL ( SELECT u.new_value AS v
                   FROM incident_updates u
                  WHERE u.incident_id = i.id AND u.kind = 'correction'::text AND u.field = 'duration_min'::text
                  ORDER BY u.id DESC
                 LIMIT 1) c_dur ON true
             LEFT JOIN LATERAL ( SELECT u.new_value AS v
                   FROM incident_updates u
                  WHERE u.incident_id = i.id AND u.kind = 'correction'::text AND u.field = 'what_happened'::text
                  ORDER BY u.id DESC
                 LIMIT 1) c_what ON true
             LEFT JOIN LATERAL ( SELECT u.new_value AS v
                   FROM incident_updates u
                  WHERE u.incident_id = i.id AND u.kind = 'correction'::text AND u.field = 'immediate_action'::text
                  ORDER BY u.id DESC
                 LIMIT 1) c_act ON true
             LEFT JOIN LATERAL ( SELECT u.new_value AS v
                   FROM incident_updates u
                  WHERE u.incident_id = i.id AND u.kind = 'correction'::text AND u.field = 'responsible_name'::text
                  ORDER BY u.id DESC
                 LIMIT 1) c_resp ON true
             LEFT JOIN LATERAL ( SELECT u.new_value AS v
                   FROM incident_updates u
                  WHERE u.incident_id = i.id AND u.kind = 'correction'::text AND u.field = 'nea_reportable'::text
                  ORDER BY u.id DESC
                 LIMIT 1) c_nea ON true) x
     LEFT JOIN safety_settings s ON s.id;

COMMENT ON VIEW public.incident_current_all IS
    'MES-7b-1:一件事故现在是什么样(更正过的值、通报 / 书面报告 / 关闭的事实、书面报告的期限与它的状态)。底视图,不授给 authenticated:读者是 incident_rows、operations_now 的两条 NEA 提醒、suggest_incident_batches 与 record_incident_update。不带受伤的细节。';

REVOKE ALL ON public.incident_current_all FROM authenticated, anon;

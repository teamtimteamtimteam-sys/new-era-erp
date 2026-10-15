-- db/functions/equipment_reliability.sql
-- MES-7a-1(2026-10-15,MES-0 Q71;MES-7a Step 0 Q5 · Q19,Tim):【一台机器多久坏一次、坏了多久修好】—— MTBF 与 MTTR,按机器、按区间。
--   ① 运转小时(分母,Q71 · Q5)= 这台机器上【已提交、未冲销】的加工单(status = committed、deleted_at 为空)的 [started_at, ended_at)
--      取【并集】、再与区间相交之后的总长。并集而不是相加:没有任何东西挡住同一台机器上两张单的时段重叠,相加会把重叠的那一段数两遍。
--      没有开始或结束时刻的单不进分母(它们的时长不知道),而它们有几张单独报出来(runs_without_times)。
--   ② 一次故障 = 一段【未作废】、原因属于 failure 类、【开始】落在区间里的停机。计划内与外部原因不算;没有原因的(本刀之前的那一行)
--      读作"未分类",也不算(unclassified_stops 单独报)。开着的一段算一次故障(它确实坏了),但不进 MTTR(还不知道修了多久)。
--   ③ MTBF = 运转小时 ÷ 故障次数。零次故障 → 没有数(mtbf_state = no_failure,页面写"N 小时的运转里没有故障");
--      零运转小时 → 没有数(no_hours,"没有记录到运转小时")—— 两者都不是 0,也不是无穷大。
--   ④ MTTR = 区间里【已经关上】的故障停机的平均时长(小时)。没有关上的故障 → NULL。
--   ⑤ 区间(Q5):p_from / p_to 由页面选;不给 = 这台机器的整段记录 —— 从它的取得日(新加坡时间零点)到此刻。不发明一个窗口。
--   ⑥ 只数停机(Q19):加工单上的 unplanned_stop 事件与停机指标是【一炉之内】的记录,不在这里数(两边都数会把一次停机数两遍)。
--   ⑦ 不算可用率、不算 OEE(Q71 只回答了可靠性的分母)。
--   runs_without_machine:区间里(按加工日)已提交、却没有记机器的单 —— 【全厂】的数,每台机器那一行都一样:它说的是"分母可能不全"。
--   只列设备类资产(Q7)。门 module.processing.view;不持的读者按名拒,不是零行(零行与"没有机器"分不开)。
--
-- NOTE: introduced by db/migrations/2026-10-15-mes7a1-equipment-reliability.sql.

CREATE OR REPLACE FUNCTION public.equipment_reliability(p_equipment_id uuid DEFAULT NULL::uuid, p_from timestamp with time zone DEFAULT NULL::timestamp with time zone, p_to timestamp with time zone DEFAULT NULL::timestamp with time zone)
 RETURNS TABLE(equipment_id uuid, equipment_code text, equipment_description text, equipment_status text, range_from timestamp with time zone, range_to timestamp with time zone, operating_hours numeric, runs_counted integer, runs_without_times integer, runs_without_machine integer, failures integer, failures_open integer, mtbf_hours numeric, mtbf_state text, mttr_hours numeric, repairs_closed integer, planned_stops integer, external_stops integer, unclassified_stops integer)
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
#variable_conflict use_column
BEGIN
    PERFORM require_permission('module.processing.view');
    IF p_from IS NOT NULL AND p_to IS NOT NULL AND p_from >= p_to THEN
        RAISE EXCEPTION 'RELIABILITY_RANGE_INVALID|%|%',
            to_char(p_from AT TIME ZONE 'Asia/Singapore', 'YYYY-MM-DD HH24:MI'), to_char(p_to AT TIME ZONE 'Asia/Singapore', 'YYYY-MM-DD HH24:MI');
    END IF;
    RETURN QUERY
    WITH m AS (
        SELECT fa.id, fa.code, fa.description, fa.status,
               COALESCE(p_from, (fa.acquisition_date::timestamp AT TIME ZONE 'Asia/Singapore')) AS f,
               COALESCE(p_to, now()) AS t
          FROM fixed_assets fa
         WHERE fa.category = 'equipment' AND (p_equipment_id IS NULL OR fa.id = p_equipment_id)
    ), w AS (
        -- 取得日在此刻之后(一台还没到的机器)= 一段空区间:一行照给,运转小时 0
        SELECT m.*, tstzrange(LEAST(m.f, m.t), m.t, '[)') AS win,
               (m.f AT TIME ZONE 'Asia/Singapore')::date AS d_from, (m.t AT TIME ZONE 'Asia/Singapore')::date AS d_to
          FROM m
    ), hrs AS (
        SELECT w.id,
               COALESCE((SELECT sum(EXTRACT(EPOCH FROM (upper(x) - lower(x))))
                           FROM unnest((SELECT range_agg(tstzrange(pr.started_at, pr.ended_at, '[)') * w.win)
                                          FROM processing_runs pr
                                         WHERE pr.equipment_id = w.id AND pr.status = 'committed' AND pr.deleted_at IS NULL
                                           AND pr.started_at IS NOT NULL AND pr.ended_at IS NOT NULL
                                           AND tstzrange(pr.started_at, pr.ended_at, '[)') && w.win)) x), 0) / 3600.0 AS op_h,
               (SELECT count(*) FROM processing_runs pr
                 WHERE pr.equipment_id = w.id AND pr.status = 'committed' AND pr.deleted_at IS NULL
                   AND pr.started_at IS NOT NULL AND pr.ended_at IS NOT NULL
                   AND tstzrange(pr.started_at, pr.ended_at, '[)') && w.win)::int AS n_runs,
               (SELECT count(*) FROM processing_runs pr
                 WHERE pr.equipment_id = w.id AND pr.status = 'committed' AND pr.deleted_at IS NULL
                   AND (pr.started_at IS NULL OR pr.ended_at IS NULL)
                   AND pr.process_date BETWEEN w.d_from AND w.d_to)::int AS n_no_times,
               (SELECT count(*) FROM processing_runs pr
                 WHERE pr.equipment_id IS NULL AND pr.status = 'committed' AND pr.deleted_at IS NULL
                   AND pr.process_date BETWEEN w.d_from AND w.d_to)::int AS n_no_machine
          FROM w
    ), dt AS (
        SELECT w.id,
               count(*) FILTER (WHERE c.class = 'failure')::int AS n_fail,
               count(*) FILTER (WHERE c.class = 'failure' AND d.ended_at IS NULL)::int AS n_fail_open,
               count(*) FILTER (WHERE c.class = 'failure' AND d.ended_at IS NOT NULL)::int AS n_fail_closed,
               avg(EXTRACT(EPOCH FROM (d.ended_at - d.started_at))) FILTER (WHERE c.class = 'failure' AND d.ended_at IS NOT NULL) / 3600.0
                   AS mttr_h,
               count(*) FILTER (WHERE c.class = 'planned')::int AS n_planned,
               count(*) FILTER (WHERE c.class = 'external')::int AS n_external,
               count(*) FILTER (WHERE d.id IS NOT NULL AND d.cause_code IS NULL)::int AS n_unclassified
          FROM w
          LEFT JOIN equipment_downtime d ON d.equipment_id = w.id AND d.voided_at IS NULL
                                        AND d.started_at >= w.f AND d.started_at < w.t
          LEFT JOIN downtime_causes c ON c.code = d.cause_code
         GROUP BY w.id
    )
    SELECT w.id, w.code, w.description, w.status, w.f, w.t,
           round(h.op_h, 2), h.n_runs, h.n_no_times, h.n_no_machine,
           dt.n_fail, dt.n_fail_open,
           CASE WHEN h.op_h > 0 AND dt.n_fail > 0 THEN round(h.op_h / dt.n_fail, 2) END,
           CASE WHEN h.op_h = 0 THEN 'no_hours' WHEN dt.n_fail = 0 THEN 'no_failure' ELSE 'value' END,
           round(dt.mttr_h, 2), dt.n_fail_closed, dt.n_planned, dt.n_external, dt.n_unclassified
      FROM w JOIN hrs h ON h.id = w.id JOIN dt ON dt.id = w.id
     ORDER BY w.code;
END;
$function$;

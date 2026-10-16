-- db/functions/suggest_incident_batches.sql
-- MES-7b-1(2026-10-16,MES-0 Q73;MES-7b Step 0 Q7,Tim):【这件事故可能碰过哪几批货】—— 只是建议,一条都不自动链上。两种,而且【不编一个时间窗】:
--   location     事故有库位时:那一刻在那个库位上有货的批 —— 那个库位上、发生时刻(更正过的)【之前或正好那一刻】的流水,按批求净数,> 0 的才列。
--                evidence = 库位编号;qty = 那一刻的净数(那一批自己的单位)。
--   machine_run  事故有机器时:那一刻正在那台机器上跑的加工单 —— 已提交、没删、[started_at, ended_at) 包含发生时刻;它的投入批与产出批。
--                没记开始或结束时刻的加工单说不出那一刻在不在跑,不列(那是一条缺了的记录,不是一条规矩)。
--                evidence = 加工单号;qty = 投入的数量 / 产出的数量。
--   already_linked:这一批现在有没有一条有效链接挂在这件事故上(页面据此把"确认"换成"已链上")。
--   一批同时由两种建议而来时各列一行(两种理由都说出来)。
--   【门】module.safety.view —— 读不到就按名拒(一个返回集合的函数用"零行"表示拒绝,与"真的没有建议"分不开 —— AGENTS.md)。
--   【DEFINER】流水、库位、加工单各有各的读策略;建议要看见的是【那一刻的事实】,不是读者恰好读得到的那几行。返回的只有批号与数量,不带价。
-- NOTE: introduced by db/migrations/2026-10-16-mes7b1-incidents.sql.
CREATE OR REPLACE FUNCTION public.suggest_incident_batches(p_incident_id uuid)
 RETURNS TABLE(batch_kind text, batch_id uuid, batch_code text, basis text, evidence text, qty numeric, already_linked boolean)
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_cur record;
BEGIN
    PERFORM require_permission('module.safety.view');
    SELECT c.id, c.occurred_at, c.location_id, c.equipment_id INTO v_cur FROM incident_current_all c WHERE c.id = p_incident_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'INCIDENT_NOT_FOUND|%', COALESCE(p_incident_id::text, '?');
    END IF;
    RETURN QUERY
    WITH s AS (
        -- ① 那一刻在事故库位上有货的批
        SELECT 'inbound'::text AS k, m.inbound_batch_id AS b, 'location'::text AS why, l.code AS ev, sum(m.qty_delta) AS q
          FROM inventory_movements m
          JOIN storage_locations l ON l.id = m.location_id
          JOIN inbound_batches ib ON ib.id = m.inbound_batch_id AND ib.deleted_at IS NULL
         WHERE v_cur.location_id IS NOT NULL AND m.location_id = v_cur.location_id AND m.occurred_at <= v_cur.occurred_at
           AND m.inbound_batch_id IS NOT NULL
         GROUP BY m.inbound_batch_id, l.code
        HAVING sum(m.qty_delta) > 0
        UNION ALL
        SELECT 'output'::text, m.output_batch_id, 'location'::text, l.code, sum(m.qty_delta)
          FROM inventory_movements m
          JOIN storage_locations l ON l.id = m.location_id
          JOIN output_batches ob ON ob.id = m.output_batch_id AND ob.deleted_at IS NULL
         WHERE v_cur.location_id IS NOT NULL AND m.location_id = v_cur.location_id AND m.occurred_at <= v_cur.occurred_at
           AND m.output_batch_id IS NOT NULL
         GROUP BY m.output_batch_id, l.code
        HAVING sum(m.qty_delta) > 0
        UNION ALL
        -- ② 那一刻在那台机器上跑的加工单的投入与产出
        SELECT CASE WHEN pi.inbound_batch_id IS NOT NULL THEN 'inbound'::text ELSE 'output'::text END,
               COALESCE(pi.inbound_batch_id, pi.output_batch_id), 'machine_run'::text, r.code, sum(pi.quantity_consumed)
          FROM processing_runs r
          JOIN processing_inputs pi ON pi.run_id = r.id
         WHERE v_cur.equipment_id IS NOT NULL AND r.equipment_id = v_cur.equipment_id AND r.status = 'committed' AND r.deleted_at IS NULL
           AND r.started_at IS NOT NULL AND r.ended_at IS NOT NULL
           AND r.started_at <= v_cur.occurred_at AND r.ended_at > v_cur.occurred_at
           AND COALESCE(pi.inbound_batch_id, pi.output_batch_id) IS NOT NULL
         GROUP BY 1, 2, r.code
        UNION ALL
        SELECT 'output'::text, po.output_batch_id, 'machine_run'::text, r.code, sum(po.quantity_produced)
          FROM processing_runs r
          JOIN processing_outputs po ON po.run_id = r.id
         WHERE v_cur.equipment_id IS NOT NULL AND r.equipment_id = v_cur.equipment_id AND r.status = 'committed' AND r.deleted_at IS NULL
           AND r.started_at IS NOT NULL AND r.ended_at IS NOT NULL
           AND r.started_at <= v_cur.occurred_at AND r.ended_at > v_cur.occurred_at
         GROUP BY po.output_batch_id, r.code
    )
    SELECT s.k, s.b, COALESCE(ib.code, ob.code), s.why, s.ev, s.q,
           EXISTS (SELECT 1 FROM incident_batches x
                    WHERE x.incident_id = p_incident_id AND x.unlinked_at IS NULL
                      AND COALESCE(x.inbound_batch_id, x.output_batch_id) = s.b)
      FROM s
      LEFT JOIN inbound_batches ib ON s.k = 'inbound' AND ib.id = s.b
      LEFT JOIN output_batches ob ON s.k = 'output' AND ob.id = s.b
     ORDER BY s.why, COALESCE(ib.code, ob.code);
END;
$function$;

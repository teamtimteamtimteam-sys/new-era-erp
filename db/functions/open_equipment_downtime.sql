-- db/functions/open_equipment_downtime.sql
-- MES-7a-1(2026-10-15,MES-7a Step 0 Q3 · Q4 · Q6,Tim):【一台机器停下来了】—— 开一段停机,结束时刻留空(= 还在停)。
--   门 module.processing.edit(记停机的是车间,与 void_equipment_downtime 同一个码;Q6:码不变,仓库不加)。
--   按名拒:不是一台在册的机器(equipment_record_target)· 没有开始时刻(DOWNTIME_START_REQUIRED —— 停机是世界那一侧的事实,
--   不给默认值)· 没有原因代号(DOWNTIME_CAUSE_REQUIRED)· 代号不在清单里(DOWNTIME_CAUSE_UNKNOWN|<代号>)或已停用
--   (DOWNTIME_CAUSE_INACTIVE|<代号>)· 没有说明(DOWNTIME_REASON_REQUIRED —— reason 仍是自由文本的说明,原因代号是分类)·
--   这台机器已经有一段开着的(DOWNTIME_ALREADY_OPEN|<那一段的开始>)。开始时刻在未来、与另一段重叠由 guard_downtime_period 按名拒。
--   来源永远是 manual(Q4:device 保留,没有转换层)。
--
-- NOTE: introduced by db/migrations/2026-10-15-mes7a1-equipment-reliability.sql.

CREATE OR REPLACE FUNCTION public.open_equipment_downtime(p_equipment_id uuid, p_started_at timestamp with time zone, p_cause_code text, p_reason text, p_notes text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_code  text;
    v_open  timestamptz;
    v_id    uuid;
BEGIN
    PERFORM require_permission('module.processing.edit');
    v_code := equipment_record_target(p_equipment_id);
    -- 同一台机器的两次开口排队(部分唯一索引是第二道)
    PERFORM 1 FROM fixed_assets fa WHERE fa.id = p_equipment_id FOR UPDATE;
    IF p_started_at IS NULL THEN
        RAISE EXCEPTION 'DOWNTIME_START_REQUIRED';
    END IF;
    PERFORM downtime_cause_check(p_cause_code);
    IF p_reason IS NULL OR btrim(p_reason) = '' THEN
        RAISE EXCEPTION 'DOWNTIME_REASON_REQUIRED';
    END IF;
    SELECT d.started_at INTO v_open FROM equipment_downtime d
     WHERE d.equipment_id = p_equipment_id AND d.ended_at IS NULL AND d.voided_at IS NULL;
    IF FOUND THEN
        RAISE EXCEPTION 'DOWNTIME_ALREADY_OPEN|%', to_char(v_open AT TIME ZONE 'Asia/Singapore', 'YYYY-MM-DD HH24:MI');
    END IF;
    BEGIN
        INSERT INTO equipment_downtime (equipment_id, started_at, ended_at, reason, notes, cause_code, source, created_by, updated_by)
        VALUES (p_equipment_id, p_started_at, NULL, btrim(p_reason), NULLIF(btrim(COALESCE(p_notes, '')), ''), p_cause_code, 'manual',
                auth.uid(), auth.uid())
        RETURNING id INTO v_id;
    EXCEPTION WHEN unique_violation THEN
        -- 两个人同一刻开(重叠判据的 SELECT 不是并发安全的,部分唯一索引是声明式的兜底):说成同一句,不是一串约束名
        RAISE EXCEPTION 'DOWNTIME_ALREADY_OPEN|%', to_char(p_started_at AT TIME ZONE 'Asia/Singapore', 'YYYY-MM-DD HH24:MI');
    END;
    RETURN jsonb_build_object('downtime_id', v_id, 'equipment_id', p_equipment_id, 'equipment_code', v_code, 'open', true);
END;
$function$;

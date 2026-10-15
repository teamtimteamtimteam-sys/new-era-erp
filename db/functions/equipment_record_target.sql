-- db/functions/equipment_record_target.sql
-- MES-7a-1(2026-10-15,MES-7a Step 0 Q6 · Q7):【这一条记录要挂的,是不是一台在册的机器】—— 五支设备记录函数共用的一句判据。
--   不存在 → EQUIPMENT_NOT_FOUND|<id>;不是设备类(车、办公电脑)→ EQUIPMENT_NOT_A_MACHINE|<编号>(/operation/equipment 只列设备类,Q7)。
--   返回资产编号,供拒绝的句子用。已处置的机器【不】在这里拒:它在役那几年的停机与保养仍然可以补记、更正。
--   【内层】不是 SECURITY DEFINER、没有调用者检查(调用方都是 DEFINER,以属主身份读 fixed_assets);EXECUTE 从 authenticated 收回。
--
-- NOTE: introduced by db/migrations/2026-10-15-mes7a1-equipment-reliability.sql.

CREATE OR REPLACE FUNCTION public.equipment_record_target(p_equipment_id uuid)
 RETURNS text
 LANGUAGE plpgsql
 STABLE
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_fa record;
BEGIN
    SELECT fa.code, fa.category INTO v_fa FROM fixed_assets fa WHERE fa.id = p_equipment_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'EQUIPMENT_NOT_FOUND|%', COALESCE(p_equipment_id::text, '?');
    END IF;
    IF v_fa.category IS DISTINCT FROM 'equipment' THEN
        RAISE EXCEPTION 'EQUIPMENT_NOT_A_MACHINE|%', v_fa.code;
    END IF;
    RETURN v_fa.code;
END;
$function$;

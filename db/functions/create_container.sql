CREATE OR REPLACE FUNCTION public.create_container(p_lane_id uuid, p_departure_date date, p_container_number text DEFAULT NULL::text, p_vessel text DEFAULT NULL::text, p_voyage text DEFAULT NULL::text, p_forwarder_id uuid DEFAULT NULL::uuid, p_bl_number text DEFAULT NULL::text, p_notes text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_id   uuid := gen_random_uuid();
    v_code text;
BEGIN
    -- 【第一步就是权限,与 ship_order 同】。这是一个 DEFINER 函数,
    -- 它以属主身份写表 —— 没有这一句,它就是一条谁都能走的后门。
    -- 用的是 containers 自己 RLS 上那个码,两处问的是同一个问题。
    PERFORM require_permission('module.purchasing.edit');

    -- 【开航日必填,且拒绝要按名】。它是世界那一侧的事实,系统永不代填;
    -- 一个 NOT NULL 抛出来的 23502 对操作员不可读(FIN-10 一族的同一条)。
    IF p_departure_date IS NULL THEN
        RAISE EXCEPTION 'CONTAINER_DEPARTURE_DATE_REQUIRED'
          USING HINT = '开航日是世界那一侧的事实,系统无从代填 —— 请填上船实际开的那一天';
    END IF;

    IF p_lane_id IS NULL THEN
        RAISE EXCEPTION 'CONTAINER_LANE_REQUIRED'
          USING HINT = '一个箱子要走哪条航段 —— 单据清单与里程碑都挂在它上面';
    END IF;

    -- 取号在【函数体内】。next_container_code 对 authenticated 是收权的,
    -- 属主身份在这里调得动它 —— 与 ship_order 调 next_shipment_code 一模一样。
    v_code := next_container_code(p_departure_date);

    -- 货代类型不在这里再判一次:trg_containers_forwarder 已经在表上判了。
    -- 【同一条规矩不写两遍】—— 两处迟早给出两个答案。
    INSERT INTO containers (id, code, container_number, vessel, voyage,
                            lane_id, forwarder_id, departure_date, bl_number, notes)
    VALUES (v_id, v_code, NULLIF(btrim(p_container_number), ''), NULLIF(btrim(p_vessel), ''),
            NULLIF(btrim(p_voyage), ''), p_lane_id, p_forwarder_id, p_departure_date,
            NULLIF(btrim(p_bl_number), ''), NULLIF(btrim(p_notes), ''));

    RETURN jsonb_build_object('id', v_id, 'code', v_code);
END;
$function$


-- db/functions/set_output_safety_states.sql
-- MES-3a(2026-10-06,MES-0 Q36;MES-3a Step 0 Q22 · Q23,Tim):一批【产出】料的安全状态 —— 与 set_inbound_safety_states 逐字同形:
--   只加新勾上的、只结束拿掉的(结束要理由,空 → SAFETY_STATE_END_REASON_REQUIRED|<状态>),没变的一个字节都不动。
--   此前产出批页面从浏览器直连插 / 删这张表(删 = 硬删,没有理由、没有墓碑,SafetyStatePanel 自己的注释这么说);
--   那两条写策略已拿掉,写只经这里(module.output.edit)与加工的提交 / 回滚。
--
-- NOTE: introduced by db/migrations/2026-10-06-mes3a-storage-safety.sql.

CREATE OR REPLACE FUNCTION public.set_output_safety_states(p_output_batch_id uuid, p_codes text[], p_end_reason text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_n      int;
    v_codes  text[] := COALESCE(p_codes, ARRAY[]::text[]);
    v_ending text;
BEGIN
    PERFORM require_permission('module.output.edit');

    IF p_output_batch_id IS NULL THEN
        RAISE EXCEPTION 'SAFETY_STATES_BATCH_REQUIRED';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM output_batches WHERE id = p_output_batch_id) THEN
        RAISE EXCEPTION 'OUTPUT_NOT_FOUND|%', p_output_batch_id;
    END IF;

    SELECT string_agg(s.safety_state_code, ',' ORDER BY s.safety_state_code) INTO v_ending
      FROM output_batch_safety_states s
     WHERE s.output_batch_id = p_output_batch_id AND s.ended_at IS NULL
       AND NOT (s.safety_state_code = ANY (v_codes));
    IF v_ending IS NOT NULL AND btrim(COALESCE(p_end_reason, '')) = '' THEN
        RAISE EXCEPTION 'SAFETY_STATE_END_REASON_REQUIRED|%', v_ending;
    END IF;

    UPDATE output_batch_safety_states s
       SET ended_at = now(), ended_by = auth.uid(), end_reason = btrim(p_end_reason)
     WHERE s.output_batch_id = p_output_batch_id AND s.ended_at IS NULL
       AND NOT (s.safety_state_code = ANY (v_codes));

    INSERT INTO output_batch_safety_states (output_batch_id, safety_state_code)
    SELECT p_output_batch_id, c FROM unnest(v_codes) c
     WHERE NOT EXISTS (SELECT 1 FROM output_batch_safety_states s
                        WHERE s.output_batch_id = p_output_batch_id AND s.ended_at IS NULL
                          AND s.safety_state_code = c);

    SELECT count(*) INTO v_n FROM output_batch_safety_states
     WHERE output_batch_id = p_output_batch_id AND ended_at IS NULL;
    RETURN jsonb_build_object('output_batch_id', p_output_batch_id, 'count', v_n);
END;
$function$;

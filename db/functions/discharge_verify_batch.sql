-- db/functions/discharge_verify_batch.sql
-- MES-5a-1(2026-10-08,规格 §3.1;MES-0 Q23 · Q24;MES-5a Step 0 Q5 · Q6,Tim):【让一批的安全状态与它的逐模组结论对上】—— 内层,唯一一处按结果改状态。
--   判据只有一份:discharge_batch_status_all.rule_verified(记了模组数,并且 当前最新为通过 + 已拆去隔离 = 模组数)。
--   ① 这一批还没有任何结论(没有当前结果、没有拆分)→ 什么都不做:结果还没开始管它(一批在 MES-5a-1 之前就核实过的料不被碰)。
--   ② 规则成立 → 结束这道工序【解决】的那几个状态(带电未放电),写上结果状态(已放电并核实),都记 p_run_id 做到的(created_by_run_id /
--      ended_by_run_id)—— 状态史与回滚照旧:回滚那一炉,它写的结束、它结束的重开(rollback_processing_run_internal)。
--   ③ 规则不成立而结果状态开着(一条更正把通过改成了失败、一炉被回滚、模组数改大了)→ 结束结果状态,重开被它解决的那个状态。
--      【安全的一侧】:一条失败的结论说这个模组没放完电,火闸就必须重新拦住这一批。
--   p_run_id 可以为空(回滚之后重判时,这一批已经没有一炉没回滚的放电了);p_note 写进结束理由。返回此刻是否开着结果状态。
--   不是 DEFINER:只被几支 DEFINER 函数调用(记 / 更正结果、改模组数、拆分、回滚);EXECUTE 从 authenticated 收回。
--
-- NOTE: introduced by db/migrations/2026-10-08-mes5a1-discharge-by-module.sql.

CREATE OR REPLACE FUNCTION public.discharge_verify_batch(p_kind text, p_batch_id uuid, p_run_id uuid, p_note text DEFAULT NULL::text)
 RETURNS boolean
 LANGUAGE plpgsql
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_s       discharge_batch_status_all%ROWTYPE;
    v_op      text;
    v_resolve text[];
    v_code    text;
    v_why     text;
BEGIN
    SELECT * INTO v_s FROM discharge_batch_status_all s WHERE s.batch_id = p_batch_id;
    IF NOT FOUND OR v_s.modules_recorded = 0 OR v_s.result_state IS NULL THEN
        RETURN COALESCE(v_s.currently_verified, false);
    END IF;

    SELECT ot.code INTO v_op FROM operation_types ot
     WHERE ot.verifies_by_unit AND ot.resulting_safety_state_code = v_s.result_state ORDER BY ot.code LIMIT 1;
    SELECT array_agg(a.safety_state_code ORDER BY a.safety_state_code) INTO v_resolve
      FROM operation_type_safety_states a WHERE a.operation_type_code = v_op AND a.resolves;
    v_code := (SELECT pr.code FROM processing_runs pr WHERE pr.id = p_run_id);
    v_why := COALESCE(NULLIF(btrim(COALESCE(p_note, '')), ''), '');

    IF v_s.rule_verified THEN
        IF v_s.currently_verified THEN
            RETURN true;
        END IF;
        IF p_kind = 'inbound' THEN
            UPDATE inbound_batch_safety_states s
               SET ended_at = now(), ended_by = auth.uid(), ended_by_run_id = p_run_id,
                   end_reason = 'verified by module results' || COALESCE(' (' || v_code || ')', '') || CASE WHEN v_why <> '' THEN ': ' || v_why ELSE '' END
             WHERE s.inbound_batch_id = p_batch_id AND s.ended_at IS NULL AND s.safety_state_code = ANY (COALESCE(v_resolve, ARRAY[]::text[]));
            INSERT INTO inbound_batch_safety_states (inbound_batch_id, safety_state_code, created_by_run_id)
            VALUES (p_batch_id, v_s.result_state, p_run_id)
            ON CONFLICT (inbound_batch_id, safety_state_code) WHERE ended_at IS NULL DO NOTHING;
        ELSE
            UPDATE output_batch_safety_states s
               SET ended_at = now(), ended_by = auth.uid(), ended_by_run_id = p_run_id,
                   end_reason = 'verified by module results' || COALESCE(' (' || v_code || ')', '') || CASE WHEN v_why <> '' THEN ': ' || v_why ELSE '' END
             WHERE s.output_batch_id = p_batch_id AND s.ended_at IS NULL AND s.safety_state_code = ANY (COALESCE(v_resolve, ARRAY[]::text[]));
            INSERT INTO output_batch_safety_states (output_batch_id, safety_state_code, created_by_run_id)
            VALUES (p_batch_id, v_s.result_state, p_run_id)
            ON CONFLICT (output_batch_id, safety_state_code) WHERE ended_at IS NULL DO NOTHING;
        END IF;
        RETURN true;
    END IF;

    IF NOT v_s.currently_verified THEN
        RETURN false;
    END IF;
    IF p_kind = 'inbound' THEN
        UPDATE inbound_batch_safety_states s
           SET ended_at = now(), ended_by = auth.uid(), ended_by_run_id = p_run_id,
               end_reason = 'module results no longer verify this batch' || COALESCE(' (' || v_code || ')', '') || CASE WHEN v_why <> '' THEN ': ' || v_why ELSE '' END
         WHERE s.inbound_batch_id = p_batch_id AND s.ended_at IS NULL AND s.safety_state_code = v_s.result_state;
        INSERT INTO inbound_batch_safety_states (inbound_batch_id, safety_state_code, created_by_run_id)
        SELECT p_batch_id, x, p_run_id FROM unnest(COALESCE(v_resolve, ARRAY[]::text[])) x
        ON CONFLICT (inbound_batch_id, safety_state_code) WHERE ended_at IS NULL DO NOTHING;
    ELSE
        UPDATE output_batch_safety_states s
           SET ended_at = now(), ended_by = auth.uid(), ended_by_run_id = p_run_id,
               end_reason = 'module results no longer verify this batch' || COALESCE(' (' || v_code || ')', '') || CASE WHEN v_why <> '' THEN ': ' || v_why ELSE '' END
         WHERE s.output_batch_id = p_batch_id AND s.ended_at IS NULL AND s.safety_state_code = v_s.result_state;
        INSERT INTO output_batch_safety_states (output_batch_id, safety_state_code, created_by_run_id)
        SELECT p_batch_id, x, p_run_id FROM unnest(COALESCE(v_resolve, ARRAY[]::text[])) x
        ON CONFLICT (output_batch_id, safety_state_code) WHERE ended_at IS NULL DO NOTHING;
    END IF;
    RETURN false;
END;
$function$

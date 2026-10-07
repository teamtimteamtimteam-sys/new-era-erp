-- db/functions/assert_run_equipment.sql
-- MES-4a(2026-10-07,MES-0 Q41;MES-4a Step 0 Q9,Tim):【这一炉的机器说得通吗】—— 一份判据,两个调用方:
--   commit_processing_run(提交)· correct_run_header(更正机器)。
--   ① 给了机器(EQP-2a 的三条,原样搬来):EQUIPMENT_NOT_FOUND · EQUIPMENT_NOT_ACQUIRED(加工日早于取得日)·
--      EQUIPMENT_DISPOSED(加工日晚于处置日)。投用之前【不】拒 —— 试车是有名有姓的事(见 commit_processing_run 原注)。
--   ② 工序 ↔ 资产(operation_type_equipment):这道工序挂着至少一台【没处置的】机器 → 必须给机器(EQUIPMENT_REQUIRED_FOR_OPERATION|<工序>),
--      而且必须是挂着的那几台之一(EQUIPMENT_NOT_LINKED_TO_OPERATION|<编号>|<工序>)。处置掉的机器不算数。
--      没挂任何机器的工序:机器可选,给了也照收(U1-B 可选选择器今天的样子;挂不挂是 Tim 的数据)。
--   【内层】不是 SECURITY DEFINER、没有调用者检查(调用方都是 DEFINER,以属主身份读 fixed_assets);EXECUTE 从 authenticated 收回。
--
-- NOTE: introduced by db/migrations/2026-10-07-mes4a-processing-record.sql (the EQP-2a checks moved here from commit_processing_run).

CREATE OR REPLACE FUNCTION public.assert_run_equipment(p_operation_type_code text, p_equipment_id uuid, p_process_date date)
 RETURNS void
 LANGUAGE plpgsql
 STABLE
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_eq     fixed_assets%ROWTYPE;
    v_linked integer;
BEGIN
    IF p_equipment_id IS NOT NULL THEN
        SELECT * INTO v_eq FROM fixed_assets WHERE id = p_equipment_id;
        IF NOT FOUND THEN
            RAISE EXCEPTION 'EQUIPMENT_NOT_FOUND|%', p_equipment_id;
        END IF;
        -- 【拒绝的边界钉在"真的不可能"上,不钉在"还没投用"上】加工日早于取得日 = 那天这台机器还不是我们的。
        IF p_process_date < v_eq.acquisition_date THEN
            RAISE EXCEPTION 'EQUIPMENT_NOT_ACQUIRED|%|%|%', v_eq.code, v_eq.acquisition_date, p_process_date
              USING HINT = '这一炉的日期早于这台机器的取得日 —— 那天它还不是我们的';
        END IF;
        -- 处置之后它已经不在了。
        IF v_eq.status = 'disposed' AND v_eq.disposal_date IS NOT NULL AND p_process_date > v_eq.disposal_date THEN
            RAISE EXCEPTION 'EQUIPMENT_DISPOSED|%|%|%', v_eq.code, v_eq.disposal_date, p_process_date
              USING HINT = '这一炉的日期晚于这台机器的处置日 —— 那时它已经不在了';
        END IF;
    END IF;

    SELECT count(*) INTO v_linked
      FROM operation_type_equipment l JOIN fixed_assets fa ON fa.id = l.fixed_asset_id
     WHERE l.operation_type_code = p_operation_type_code AND fa.status <> 'disposed';
    IF v_linked > 0 THEN
        IF p_equipment_id IS NULL THEN
            RAISE EXCEPTION 'EQUIPMENT_REQUIRED_FOR_OPERATION|%', p_operation_type_code
              USING HINT = '这道工序挂着机器 —— 选这一炉跑在哪一台上。';
        END IF;
        IF NOT EXISTS (SELECT 1 FROM operation_type_equipment l JOIN fixed_assets fa ON fa.id = l.fixed_asset_id
                        WHERE l.operation_type_code = p_operation_type_code AND l.fixed_asset_id = p_equipment_id
                          AND fa.status <> 'disposed') THEN
            RAISE EXCEPTION 'EQUIPMENT_NOT_LINKED_TO_OPERATION|%|%', v_eq.code, p_operation_type_code
              USING HINT = '这台机器没有挂在这道工序上(或已处置)。在工序页上挂上它,或选挂着的那一台。';
        END IF;
    END IF;
END;
$function$

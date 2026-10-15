-- db/functions/record_equipment_maintenance.sql
-- MES-7a-1(2026-10-15,MES-7a Step 0 Q6,Tim):【记一次保养或维修】—— 取代 EQP-2d 的直连 INSERT。门 module.processing.edit。
--   本表一分钱都不过(表注那一句不变):支出只被【指着】(p_expense_id),资本化的钱照旧只经 record_expense。
--   【可以点名它修好的那一段停机】(equipment_maintenance.downtime_id 此前没有任何写入方、也没有守卫)——
--   只能是【同一台机器】的、【没有作废】的一段:MAINTENANCE_DOWNTIME_OTHER_MACHINE|<那一段的开始>|<那台机器的编号> ·
--   MAINTENANCE_DOWNTIME_VOIDED|<开始> · MAINTENANCE_DOWNTIME_NOT_FOUND|<id>。开着的一段可以点名(修理常在机器回来之前就记下)。
--   其余按名拒(此前是约束名):不是一台在册的机器 · MAINT_DATE_REQUIRED(干活的日期是世界那一侧的事实,不给默认值)·
--   MAINT_KIND_INVALID|<种类> · MAINT_DESCRIPTION_REQUIRED · MAINT_PERFORMER_REQUIRED(谁做的,至少说出一个)·
--   MAINT_PERFORMER_AMBIGUOUS(员工与供应商只能二选一)· MAINT_EMPLOYEE_NOT_FOUND · MAINT_SUPPLIER_NOT_FOUND · MAINT_EXPENSE_NOT_FOUND ·
--   MAINT_REASON_REQUIRED(说要资本化,就得说为什么)。表上的 CHECK 留着,做直连那条路之外的第二道。
--
-- NOTE: introduced by db/migrations/2026-10-15-mes7a1-equipment-reliability.sql.

CREATE OR REPLACE FUNCTION public.record_equipment_maintenance(p_equipment_id uuid, p_performed_on date, p_kind text, p_description text, p_performed_by_employee_id uuid DEFAULT NULL::uuid, p_performed_by_supplier_id uuid DEFAULT NULL::uuid, p_performed_by_name text DEFAULT NULL::text, p_downtime_id uuid DEFAULT NULL::uuid, p_expense_id uuid DEFAULT NULL::uuid, p_capitalised boolean DEFAULT false, p_capitalisation_reason text DEFAULT NULL::text, p_notes text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_code  text;
    v_name  text := NULLIF(btrim(COALESCE(p_performed_by_name, '')), '');
    v_dt    record;
    v_id    uuid;
BEGIN
    PERFORM require_permission('module.processing.edit');
    v_code := equipment_record_target(p_equipment_id);
    IF p_performed_on IS NULL THEN
        RAISE EXCEPTION 'MAINT_DATE_REQUIRED';
    END IF;
    IF p_kind IS NULL OR p_kind NOT IN ('service', 'repair') THEN
        RAISE EXCEPTION 'MAINT_KIND_INVALID|%', COALESCE(p_kind, '?');
    END IF;
    IF p_description IS NULL OR btrim(p_description) = '' THEN
        RAISE EXCEPTION 'MAINT_DESCRIPTION_REQUIRED';
    END IF;
    IF p_performed_by_employee_id IS NOT NULL AND p_performed_by_supplier_id IS NOT NULL THEN
        RAISE EXCEPTION 'MAINT_PERFORMER_AMBIGUOUS';
    END IF;
    IF p_performed_by_employee_id IS NULL AND p_performed_by_supplier_id IS NULL AND v_name IS NULL THEN
        RAISE EXCEPTION 'MAINT_PERFORMER_REQUIRED';
    END IF;
    IF p_performed_by_employee_id IS NOT NULL AND NOT EXISTS (SELECT 1 FROM employees e WHERE e.id = p_performed_by_employee_id) THEN
        RAISE EXCEPTION 'MAINT_EMPLOYEE_NOT_FOUND|%', p_performed_by_employee_id;
    END IF;
    IF p_performed_by_supplier_id IS NOT NULL AND NOT EXISTS (SELECT 1 FROM suppliers s WHERE s.id = p_performed_by_supplier_id) THEN
        RAISE EXCEPTION 'MAINT_SUPPLIER_NOT_FOUND|%', p_performed_by_supplier_id;
    END IF;
    IF p_expense_id IS NOT NULL AND NOT EXISTS (SELECT 1 FROM expenses x WHERE x.id = p_expense_id) THEN
        RAISE EXCEPTION 'MAINT_EXPENSE_NOT_FOUND|%', p_expense_id;
    END IF;
    IF COALESCE(p_capitalised, false) AND (p_capitalisation_reason IS NULL OR btrim(p_capitalisation_reason) = '') THEN
        RAISE EXCEPTION 'MAINT_REASON_REQUIRED';
    END IF;
    IF p_downtime_id IS NOT NULL THEN
        SELECT d.equipment_id, d.voided_at, d.started_at, fa.code AS machine INTO v_dt
          FROM equipment_downtime d JOIN fixed_assets fa ON fa.id = d.equipment_id WHERE d.id = p_downtime_id;
        IF NOT FOUND THEN
            RAISE EXCEPTION 'MAINTENANCE_DOWNTIME_NOT_FOUND|%', p_downtime_id;
        END IF;
        IF v_dt.equipment_id <> p_equipment_id THEN
            RAISE EXCEPTION 'MAINTENANCE_DOWNTIME_OTHER_MACHINE|%|%',
                to_char(v_dt.started_at AT TIME ZONE 'Asia/Singapore', 'YYYY-MM-DD HH24:MI'), v_dt.machine;
        END IF;
        IF v_dt.voided_at IS NOT NULL THEN
            RAISE EXCEPTION 'MAINTENANCE_DOWNTIME_VOIDED|%', to_char(v_dt.started_at AT TIME ZONE 'Asia/Singapore', 'YYYY-MM-DD HH24:MI');
        END IF;
    END IF;
    INSERT INTO equipment_maintenance (equipment_id, performed_on, kind, description, performed_by_employee_id,
                                       performed_by_supplier_id, performed_by_name, downtime_id, expense_id, capitalised,
                                       capitalisation_reason, notes, created_by, updated_by)
    VALUES (p_equipment_id, p_performed_on, p_kind, btrim(p_description), p_performed_by_employee_id, p_performed_by_supplier_id,
            v_name, p_downtime_id, p_expense_id, COALESCE(p_capitalised, false),
            CASE WHEN COALESCE(p_capitalised, false) THEN btrim(p_capitalisation_reason) END,
            NULLIF(btrim(COALESCE(p_notes, '')), ''), auth.uid(), auth.uid())
    RETURNING id INTO v_id;
    RETURN jsonb_build_object('maintenance_id', v_id, 'equipment_id', p_equipment_id, 'equipment_code', v_code);
END;
$function$;

-- db/functions/compliance_pack_data.sql
-- MES-8b-1(2026-10-17,MES-0 Q82;MES-8 Step 0 Q14 · Q15 · Q18 · Q22 · Q28,Tim):【一个日历月的合规包 —— 现算的那一份】。
--   ★ 一份实现,两个调用方:合规包页的实时预览与 freeze_compliance_pack(它把这里的返回值原样冻进 payload —— 在那里重算一遍就是第二份实现)。
--   ★ 八节(Q14),都只读这一个月、都按新加坡日期:
--     1 processing_balance   那个月的物料平衡,全厂(scope = plant)与每道工序(scope = operation)—— processing_balance_monthly_all 原样
--     2 stock_rollforward    那个月的库存滚动(期初 · 收货 · 产出 · 消耗 · 售出 · 注销 · 调整 · 作废 · 出给保养 · 移库 · 期末)—— stock_rollforward_monthly_all 原样
--     3 licence              月末那一天在效的废物处置执照(storage_licence_in_force(月末),与收货判上限同一条挑法)· 月末按 NEA 类别的在库吨数
--                            (流水 business_date ≤ 月末之和,按物料此刻的类别归类 —— nea_category_on_hand_all 的同一个口径,截到月末)与执照下每一类的上限 ·
--                            没有类别的在库吨数 · 当月每一种上限判定的次数(receipt_ceiling_checks,按 checked_on)
--     4 incidents            当月发生的事故:编号、种类、要不要通报 NEA、通报的日子、交书面报告的日子、期限与它的状态、关闭的日子 ——
--                            【不带任何受伤的细节】(谁受伤、伤情、处置、损失天数、外人的名字),也不带任何一段人写的文字(经过、处置、负责人的名字):
--                            读的是 incident_current_all,那张视图本来就不带受伤的那几列(Q14 · Q22)
--     5 environmental        当月取样的监测结果:参数、取样点、日子、数、单位、抄在结果上的限值与它的方向、判词(exceeds / within / not judged)、
--                            它开的那件事故与它更正的那一条
--     6 inspections          当月做过的巡检(编号、清单、片区、日子、合格 / 不合格 / 不适用的项数、被谁更正)与【月末】还开着的发现:
--                            巡检日在月末或之前、到月末还没有关闭的(一条发现属于它那一次巡检 —— 记下它的时刻可以晚于巡检那一天);
--                            带那一次巡检、那一项的字、纠正措施、到期日、从巡检日到月末开了几天 —— 发现里不带人名
--     7 nea_return           V26:格式与频率给了就照原样印,没给就是「NEA return — format not yet set (V26)」;【本系统不出 NEA 申报表】
--     8 eu_efficiency        V27:方法没给就是「method not yet set (V27)」,旁边放这个月的投入与各形态产出(第 1 节的同一组数)—— 不算效率(Q28)
--   ★ 不带钱:没有一个价、一笔金额、一个工资数(Q22)。不带人名。
--   ★ 门:module.compliance.view(Q17)。SECURITY DEFINER —— 它读的几张基视图刻意不给员工读(MES-5b 的平衡、MES-3a 的 NEA 在库、MES-7b 的事故现值),
--     读者只要合规的查看码就能读一份完整的包(Q17:包是以属主权限冻下来的)。
-- NOTE: introduced by db/migrations/2026-10-17-mes8b1-margin-exposure-and-compliance-pack.sql.
CREATE OR REPLACE FUNCTION public.compliance_pack_data(p_month date)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_start    date;
    v_end      date;
    v_fs       finance_settings%ROWTYPE;
    v_cs       compliance_settings%ROWTYPE;
    v_lic_id   uuid;
    v_lic      jsonb;
    v_company  jsonb;
    v_balance  jsonb;
    v_roll     jsonb;
    v_cats     jsonb;
    v_uncat    numeric;
    v_undated  bigint;
    v_checks   jsonb;
    v_inc      jsonb;
    v_env      jsonb;
    v_runs     jsonb;
    v_open     jsonb;
    v_masses   jsonb;
BEGIN
    PERFORM require_permission('module.compliance.view');
    IF p_month IS NULL THEN
        RAISE EXCEPTION 'COMPLIANCE_PACK_PERIOD_REQUIRED';
    END IF;
    v_start := date_trunc('month', p_month)::date;
    v_end   := (v_start + INTERVAL '1 month - 1 day')::date;
    SELECT * INTO v_fs FROM finance_settings;
    SELECT * INTO v_cs FROM compliance_settings WHERE id;

    SELECT jsonb_build_object('legal_name', cp.legal_name, 'registration_no', cp.registration_no, 'address_lines', cp.address_lines,
                              'city', cp.city, 'postal_code', cp.postal_code, 'country', cp.country, 'phone', cp.phone, 'email', cp.email,
                              'website', cp.website)
      INTO v_company FROM company_profile cp LIMIT 1;

    -- 1 · 物料平衡
    SELECT COALESCE(jsonb_agg(jsonb_build_object('scope', b.scope, 'operation_type_code', b.operation_type_code, 'line', b.line,
                                                 'line_key', b.line_key, 'basis', b.basis, 'qty_kg', b.qty, 'runs', b.runs)
                              ORDER BY b.scope DESC, b.operation_type_code NULLS FIRST, b.line, b.line_key NULLS FIRST, b.basis NULLS FIRST), '[]'::jsonb)
      INTO v_balance FROM processing_balance_monthly_all b WHERE b.month = v_start;

    -- 2 · 库存滚动
    SELECT COALESCE(jsonb_agg(jsonb_build_object('unit', r.unit, 'opening', r.opening, 'received', r.received, 'produced', r.produced,
                                                 'consumed', r.consumed, 'sold', r.sold, 'written_off', r.written_off, 'adjusted', r.adjusted,
                                                 'voided', r.voided, 'issued_to_maintenance', r.issued_to_maintenance, 'moved', r.moved,
                                                 'closing', r.closing) ORDER BY r.unit), '[]'::jsonb)
      INTO v_roll FROM stock_rollforward_monthly_all r WHERE r.month = v_start;

    -- 3 · 执照、月末按 NEA 类别的在库、当月的上限判定
    v_lic_id := storage_licence_in_force(v_end);
    SELECT jsonb_build_object('cert_type_code', c.cert_type_code, 'cert_no', c.cert_no, 'issuing_body', c.issuing_body, 'scope', c.scope,
                              'valid_from', c.valid_from, 'valid_until', c.valid_until, 'approved_storage_limit_tonnes', c.approved_storage_limit_tonnes)
      INTO v_lic FROM company_compliance c WHERE c.id = v_lic_id;
    WITH bal AS (
        SELECT b.material_id, b.unit, sum(mv.qty_delta) AS qty
          FROM inventory_movements mv JOIN inbound_batches b ON b.id = mv.inbound_batch_id
         WHERE mv.business_date <= v_end GROUP BY b.id, b.material_id, b.unit
        UNION ALL
        SELECT b.material_id, b.unit, sum(mv.qty_delta)
          FROM inventory_movements mv JOIN output_batches b ON b.id = mv.output_batch_id
         WHERE mv.business_date <= v_end GROUP BY b.id, b.material_id, b.unit
    ), cat AS (
        SELECT m.nea_waste_category_code AS code, count(*) AS batches, sum(quantity_in_tonnes(bal.qty, bal.unit)) AS tonnes,
               count(*) FILTER (WHERE quantity_in_tonnes(bal.qty, bal.unit) IS NULL) AS unconvertible_batches
          FROM bal JOIN materials m ON m.id = bal.material_id
         WHERE bal.qty <> 0 AND m.nea_waste_category_code IS NOT NULL GROUP BY m.nea_waste_category_code
    )
    SELECT COALESCE(jsonb_agg(jsonb_build_object('category_code', k.code, 'name_en', k.name_en, 'batches', COALESCE(cat.batches, 0),
                                                 'tonnes', COALESCE(round(cat.tonnes, 3), 0), 'unconvertible_batches', COALESCE(cat.unconvertible_batches, 0),
                                                 'limit_tonnes', l.limit_tonnes,
                                                 'state', CASE WHEN v_lic_id IS NULL THEN 'licence_not_in_force' WHEN l.limit_tonnes IS NULL THEN 'ceiling_not_set'
                                                               WHEN COALESCE(cat.tonnes, 0) > l.limit_tonnes THEN 'above_ceiling' ELSE 'within_ceiling' END)
                              ORDER BY k.sort_order, k.code), '[]'::jsonb)
      INTO v_cats
      FROM nea_waste_categories k
      LEFT JOIN cat ON cat.code = k.code
      LEFT JOIN licence_storage_limits l ON l.licence_id = v_lic_id AND l.category_code = k.code
     WHERE k.is_active OR cat.code IS NOT NULL;
    WITH bal AS (
        SELECT b.material_id, b.unit, sum(mv.qty_delta) AS qty
          FROM inventory_movements mv JOIN inbound_batches b ON b.id = mv.inbound_batch_id
         WHERE mv.business_date <= v_end GROUP BY b.id, b.material_id, b.unit
        UNION ALL
        SELECT b.material_id, b.unit, sum(mv.qty_delta)
          FROM inventory_movements mv JOIN output_batches b ON b.id = mv.output_batch_id
         WHERE mv.business_date <= v_end GROUP BY b.id, b.material_id, b.unit
    )
    SELECT COALESCE(round(sum(quantity_in_tonnes(bal.qty, bal.unit)), 3), 0) INTO v_uncat
      FROM bal JOIN materials m ON m.id = bal.material_id WHERE bal.qty <> 0 AND m.nea_waste_category_code IS NULL;
    SELECT count(*) INTO v_undated FROM inventory_movements mv WHERE mv.business_date IS NULL;
    SELECT COALESCE(jsonb_agg(jsonb_build_object('outcome', x.outcome, 'category_code', x.category_code, 'checks', x.n) ORDER BY x.outcome, x.category_code NULLS FIRST), '[]'::jsonb)
      INTO v_checks
      FROM (SELECT c.outcome, c.category_code, count(*) AS n FROM receipt_ceiling_checks c
             WHERE c.checked_on BETWEEN v_start AND v_end GROUP BY c.outcome, c.category_code) x;

    -- 4 · 事故(不带受伤的细节、不带人写的文字)
    SELECT COALESCE(jsonb_agg(jsonb_build_object('code', i.code, 'kind_code', i.kind_code, 'kind_name_en', k.name_en, 'occurred_on', i.occurred_on,
                                                 'nea_reportable', i.nea_reportable,
                                                 'notified_on', (i.notified_at AT TIME ZONE 'Asia/Singapore')::date,
                                                 'report_submitted_on', (i.report_submitted_at AT TIME ZONE 'Asia/Singapore')::date,
                                                 'report_deadline', i.report_deadline, 'deadline_state', i.deadline_state,
                                                 'closed_on', (i.closed_at AT TIME ZONE 'Asia/Singapore')::date)
                              ORDER BY i.occurred_at, i.code), '[]'::jsonb)
      INTO v_inc
      FROM incident_current_all i LEFT JOIN incident_kinds k ON k.code = i.kind_code
     WHERE i.occurred_on BETWEEN v_start AND v_end;

    -- 5 · 环境监测
    SELECT COALESCE(jsonb_agg(jsonb_build_object('parameter_code', r.parameter_code, 'parameter_name_en', p.name_en, 'sample_point', r.sample_point,
                                                 'sampled_on', r.sampled_on, 'value', r.value, 'unit', r.unit, 'limit_value', r.limit_value,
                                                 'limit_basis', r.limit_basis,
                                                 'judgement', CASE WHEN r.exceeds IS NULL THEN 'not_judged' WHEN r.exceeds THEN 'exceeds' ELSE 'within' END,
                                                 'incident_code', inc.code,
                                                 'corrects', (SELECT o.sampled_on::text || ' ' || o.parameter_code FROM environmental_results o WHERE o.id = r.corrects_result_id),
                                                 'superseded', EXISTS (SELECT 1 FROM environmental_results n WHERE n.corrects_result_id = r.id))
                              ORDER BY r.sampled_on, r.parameter_code, r.recorded_at), '[]'::jsonb)
      INTO v_env
      FROM environmental_results r
      LEFT JOIN environmental_parameters p ON p.code = r.parameter_code
      LEFT JOIN incidents inc ON inc.id = r.incident_id
     WHERE r.sampled_on BETWEEN v_start AND v_end;

    -- 6 · 巡检与月末还开着的发现
    SELECT COALESCE(jsonb_agg(jsonb_build_object('code', r.code, 'template_code', r.template_code, 'template_name', r.template_name, 'area', r.template_area,
                                                 'inspected_on', (r.inspected_at AT TIME ZONE 'Asia/Singapore')::date,
                                                 'passed', (SELECT count(*) FROM inspection_results x WHERE x.run_id = r.id AND x.result = 'pass'),
                                                 'failed', (SELECT count(*) FROM inspection_results x WHERE x.run_id = r.id AND x.result = 'fail'),
                                                 'not_applicable', (SELECT count(*) FROM inspection_results x WHERE x.run_id = r.id AND x.result = 'na'),
                                                 'corrects', (SELECT o.code FROM inspection_runs o WHERE o.id = r.corrects_run_id),
                                                 'corrected_by', (SELECT n.code FROM inspection_runs n WHERE n.corrects_run_id = r.id ORDER BY n.recorded_at LIMIT 1))
                              ORDER BY r.inspected_at, r.code), '[]'::jsonb)
      INTO v_runs
      FROM inspection_runs r
     WHERE (r.inspected_at AT TIME ZONE 'Asia/Singapore')::date BETWEEN v_start AND v_end;
    SELECT COALESCE(jsonb_agg(jsonb_build_object('run_code', r.code, 'item', x.item_text, 'corrective_action', f.corrective_action, 'due_date', f.due_date,
                                                 'inspected_on', (r.inspected_at AT TIME ZONE 'Asia/Singapore')::date,
                                                 'days_open_at_month_end', v_end - (r.inspected_at AT TIME ZONE 'Asia/Singapore')::date)
                              ORDER BY r.inspected_at, r.code, f.recorded_at), '[]'::jsonb)
      INTO v_open
      FROM inspection_findings f JOIN inspection_runs r ON r.id = f.run_id LEFT JOIN inspection_results x ON x.id = f.result_id
     WHERE (r.inspected_at AT TIME ZONE 'Asia/Singapore')::date <= v_end
       AND NOT EXISTS (SELECT 1 FROM inspection_finding_closures c WHERE c.finding_id = f.id
                        AND (c.closed_at AT TIME ZONE 'Asia/Singapore')::date <= v_end);

    -- 8 · 第 1 节里与回收效率有关的那几个数(全厂):投入与各形态的产出
    SELECT jsonb_build_object(
               'input_kg', COALESCE((SELECT sum(b.qty) FROM processing_balance_monthly_all b WHERE b.month = v_start AND b.scope = 'plant' AND b.line = 'input'), 0),
               'outputs', COALESCE((SELECT jsonb_agg(jsonb_build_object('form', b.line_key, 'qty_kg', b.qty) ORDER BY b.line_key)
                                      FROM processing_balance_monthly_all b WHERE b.month = v_start AND b.scope = 'plant' AND b.line = 'output'), '[]'::jsonb))
      INTO v_masses;

    RETURN jsonb_build_object(
        'month', to_char(v_start, 'YYYY-MM'), 'period_start', v_start, 'period_end', v_end,
        'locked_before', v_fs.locked_before, 'month_locked', v_fs.locked_before IS NOT NULL AND v_fs.locked_before > v_end,
        'system_start_date', v_fs.system_start_date,
        'company', v_company,
        'processing_balance', v_balance,
        'stock_rollforward', v_roll,
        'licence', jsonb_build_object('in_force', v_lic, 'on_hand_by_category', v_cats, 'uncategorised_tonnes', v_uncat,
                                      'movements_without_business_date', v_undated, 'ceiling_checks', v_checks),
        'incidents', v_inc,
        'environmental', v_env,
        'inspections', jsonb_build_object('done', v_runs, 'findings_open_at_month_end', v_open),
        'nea_return', CASE WHEN v_cs.nea_return_format IS NULL OR v_cs.nea_return_frequency IS NULL
                           THEN jsonb_build_object('state', 'not_set', 'value_code', 'V26')
                           ELSE jsonb_build_object('state', 'set', 'value_code', 'V26', 'format', v_cs.nea_return_format, 'frequency', v_cs.nea_return_frequency) END,
        'eu_efficiency', CASE WHEN v_cs.eu_efficiency_method IS NULL OR v_cs.eu_efficiency_targets IS NULL
                              THEN jsonb_build_object('state', 'not_set', 'value_code', 'V27', 'masses', v_masses)
                              ELSE jsonb_build_object('state', 'set', 'value_code', 'V27', 'method', v_cs.eu_efficiency_method,
                                                      'targets', v_cs.eu_efficiency_targets, 'masses', v_masses, 'computed', false) END);
END;
$function$

-- db/functions/return_spare_parts.sql
-- MES-7a-2(2026-10-16,MES-7a Step 0 Q12 · Q15,Tim):【把出给保养的备件退回库里】—— 一次出库的更正,也是拆下来没用上的件回库。
--   一行 maintenance_part_issues(kind = return,引用它退的那一行出库,带理由)、一条 maintenance_return 流水(可用桶,为正)、
--   一张分录(借 1200 / 贷 6800 —— 出库那一张反过来)。码 module.inventory.edit;没有审批(Q10)。
--   ★ 必须说理由(Q12):PART_RETURN_REASON_REQUIRED。必须引用一行出库:PART_ISSUE_NOT_FOUND|<id>(找不到,或那一行本身是一次退回)。
--   ★ 退的不能多于那一行还没退的(出库数量 − 已退的):PART_RETURN_EXCEEDS_ISSUED|<批号>|<还可退>|<要退的>。
--   ★ 日期必填、不在未来、不早于那一次出库:PART_RETURN_DATE_REQUIRED · PART_RETURN_DATE_IN_FUTURE · PART_RETURN_BEFORE_ISSUE|<出库日>。
--   ★ 那一批已经注销了 → PART_RETURN_BATCH_WRITTEN_OFF|<批号>:一批注销掉的货不再收回东西(它的剩余量已归零、价值已进 5200)。
--   ★ 质量暂扣【不挡】退回(Q15):退回不在 guard_quality_hold 的名单上;那一批在不在暂扣里,下一次出库时再问。
--   ★ 退回落在"未指定库位"(location_id 为空,可用桶)—— 从机器上拆回来的件还没放上任何货架,上架是一次转移(加工产出同一条规矩);
--     出库当时从哪几个库位取的,不替人猜回去。
--   ★ 金额 = 退回前后两次计值之差(issue_spare_parts 抬头那一条,方向相反),落地单价照【今天的】读 —— 一次改价已经把出给保养那一份的价差
--     记进了 6800(reprice_split),所以照今天的单价退,1200 才与 round(剩余 × 落地单价, 2) 逐分对得上。
-- NOTE: introduced by db/migrations/2026-10-16-mes7a2-spare-parts.sql.

CREATE OR REPLACE FUNCTION public.return_spare_parts(p_issue_id uuid, p_quantity numeric, p_returned_on date, p_reason text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_user     uuid := auth.uid();
    v_today    date := (now() AT TIME ZONE 'Asia/Singapore')::date;
    v_iss      record;
    v_b        record;
    v_left     numeric;
    v_id       uuid := gen_random_uuid();
    v_cost     numeric;
    v_before   numeric;
    v_after    numeric;
    v_amt      numeric;
    v_mv       uuid;
    v_je       jsonb;
BEGIN
    PERFORM require_permission('module.inventory.edit');
    IF p_reason IS NULL OR btrim(p_reason) = '' THEN
        RAISE EXCEPTION 'PART_RETURN_REASON_REQUIRED';
    END IF;
    IF p_returned_on IS NULL THEN
        RAISE EXCEPTION 'PART_RETURN_DATE_REQUIRED';
    END IF;
    IF p_returned_on > v_today THEN
        RAISE EXCEPTION 'PART_RETURN_DATE_IN_FUTURE|%', p_returned_on;
    END IF;

    SELECT i.id, i.maintenance_id, i.inbound_batch_id, i.quantity, i.business_date, fa.code AS asset_code, m.performed_on
      INTO v_iss
      FROM maintenance_part_issues i
      JOIN equipment_maintenance m ON m.id = i.maintenance_id
      JOIN fixed_assets fa ON fa.id = m.equipment_id
     WHERE i.id = p_issue_id AND i.kind = 'issue'
       FOR UPDATE OF i;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'PART_ISSUE_NOT_FOUND|%', COALESCE(p_issue_id::text, '?');
    END IF;
    IF p_returned_on < v_iss.business_date THEN
        RAISE EXCEPTION 'PART_RETURN_BEFORE_ISSUE|%', v_iss.business_date;
    END IF;

    SELECT b.code, b.remaining_qty, b.deleted_at INTO v_b FROM inbound_batches b WHERE b.id = v_iss.inbound_batch_id FOR UPDATE;
    IF v_b.deleted_at IS NOT NULL THEN
        RAISE EXCEPTION 'PART_RETURN_BATCH_WRITTEN_OFF|%', v_b.code;
    END IF;
    IF p_quantity IS NULL OR p_quantity <= 0 THEN
        RAISE EXCEPTION 'PART_QTY_INVALID|%|%', v_b.code, COALESCE(p_quantity::text, '?');
    END IF;
    SELECT v_iss.quantity - COALESCE(sum(r.quantity), 0) INTO v_left
      FROM maintenance_part_issues r WHERE r.returns_issue_id = p_issue_id;
    IF p_quantity > v_left THEN
        RAISE EXCEPTION 'PART_RETURN_EXCEEDS_ISSUED|%|%|%', v_b.code, v_left, p_quantity;
    END IF;

    v_before := v_b.remaining_qty;
    v_after  := v_before + p_quantity;
    v_cost   := inbound_batch_landed_unit_cost_all(v_iss.inbound_batch_id);

    PERFORM set_config('evoltrya.part_issue_ctx', 'return', true);
    UPDATE inbound_batches
       SET remaining_qty = v_after, updated_by = v_user, updated_at = now()
     WHERE id = v_iss.inbound_batch_id;
    INSERT INTO inventory_movements (inbound_batch_id, movement_type, qty_delta, stock_status, location_id, business_date, notes, created_by)
    VALUES (v_iss.inbound_batch_id, 'maintenance_return', p_quantity, 'available', NULL, p_returned_on,
            'Returned from ' || v_iss.asset_code || ' maintenance of ' || v_iss.performed_on || ': ' || btrim(p_reason), v_user)
    RETURNING id INTO v_mv;
    PERFORM set_config('evoltrya.part_issue_ctx', '', true);

    v_amt := round(v_after * COALESCE(v_cost, 0), 2) - round(v_before * COALESCE(v_cost, 0), 2);
    IF v_amt <> 0 THEN
        v_je := post_journal_entry(
            p_returned_on,
            'Spare parts ' || v_b.code || ' returned from ' || v_iss.asset_code || ' maintenance of ' || v_iss.performed_on,
            'maintenance_part', v_id,
            jsonb_build_array(
                jsonb_build_object('account_code', '1200', 'side', 'debit',  'currency', base_currency_code(), 'amount_ccy', v_amt),
                jsonb_build_object('account_code', '6800', 'side', 'credit', 'currency', base_currency_code(), 'amount_ccy', v_amt)));
    END IF;

    INSERT INTO maintenance_part_issues (id, maintenance_id, inbound_batch_id, kind, returns_issue_id, quantity, business_date,
                                         reason, movement_ids, journal_entry_id, created_by)
    VALUES (v_id, v_iss.maintenance_id, v_iss.inbound_batch_id, 'return', p_issue_id, p_quantity, p_returned_on,
            btrim(p_reason), ARRAY[v_mv], (v_je ->> 'entry_id')::uuid, v_user);

    RETURN jsonb_build_object('return_id', v_id, 'issue_id', p_issue_id, 'batch_code', v_b.code, 'quantity', p_quantity,
                              'journal_code', v_je ->> 'code');
END;
$function$;

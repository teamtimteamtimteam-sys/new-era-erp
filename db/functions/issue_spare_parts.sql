-- db/functions/issue_spare_parts.sql
-- MES-7a-2(2026-10-16,MES-0 Q70 · Q89;MES-7a Step 0 Q10–Q15,Tim):【把备件出给一条保养记录】。
--   p_lines = [{inbound_batch_id, quantity}, …];每一条明细写一行 maintenance_part_issues(kind = issue)、一到几条 maintenance_issue 流水
--   (drain_stock 从可用桶里取,可能跨几个库位桶)、一张分录(借 6800 Repairs & Maintenance / 贷 1200,按那一批的落地单价)。
--   ★ 码 module.inventory.edit(Q12,不加新码);没有审批(Q10 · MES-0 §4.1:一次出库是一条库存流水,与加工投料同一类)。
--   ★ 只出 spare_part 那一种物料的批(Q12):PART_NOT_SPARE_PART|<批号>|<种类>。
--   ★ 只出给没有资本化的保养记录(Q14):PART_ISSUE_CAPITALISED|<机器>|<日期> —— 一条资本化了的大修,它的钱经费用单进资产成本;
--     从库里出的件没有一条路进资产成本,照费用记掉会少计资产("备件进资本化大修"登记在 docs/known-issues.md)。
--     ★ 保养记录【没有作废】这件事(没有作废列、没有作废函数、删除被拒)—— 委托书说的"未作废"在今天没有主语;fixture 266 的 VOID 臂
--       断言这一点,谁给保养记录加一个作废,那一臂就红,逼他回来这里加一道拒绝。
--   ★ 数量 ≤ 可用(Q12):PART_ISSUE_EXCEEDS_AVAILABLE|<批号>|<可用>|<要出的>(同一批分几条明细时按合计判)。
--   ★ 没定价的批不出(Q13):SPARE_PART_UNPRICED|<批号> —— 一次照 0 过账的维修费会少计这次修理;暂定价(provisional)是价,照出。
--   ★ 质量暂扣挡出库(Q15):一批有开着的不合格报告的备件,流水上的 guard_quality_hold 按名拒 QUALITY_HOLD_OPEN|<批号>|<报告>。
--   ★ 日期必填、不默认,不许在未来(AGENTS.md「决定期间的日期」):PART_ISSUE_DATE_REQUIRED · PART_ISSUE_DATE_IN_FUTURE。分录按它记账,
--     期间锁由 post_journal_entry → assert_posting_allowed 判。
--   ★ 【金额 = 出库前后两次计值之差】round(出库前剩余 × 落地单价, 2) − round(出库后剩余 × 落地单价, 2),而不是 round(数量 × 单价, 2):
--     存货的明细侧(inventory_control_reconciliation 的 batch_side)就是 round(剩余 × 落地单价, 2),这样记 1200 才逐分跟着它走 ——
--     两种取整在一个三位小数的单价上会差一分钱,而那一分钱会落进"未解释"。落地单价读 inbound_batch_landed_unit_cost_all(无判据的过账原语:
--     账上的金额不许取决于按按钮的人看不看得见价格)。
--   DEFINER:写流水、批次与分录都只能经属主路径;它自己 require_permission。
-- NOTE: introduced by db/migrations/2026-10-16-mes7a2-spare-parts.sql.

CREATE OR REPLACE FUNCTION public.issue_spare_parts(p_maintenance_id uuid, p_issued_on date, p_lines jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_user     uuid := auth.uid();
    v_today    date := (now() AT TIME ZONE 'Asia/Singapore')::date;
    v_maint    record;
    v_line     jsonb;
    v_batch    uuid;
    v_qty      numeric;
    v_b        record;
    v_avail    numeric;
    v_id       uuid;
    v_cost     numeric;
    v_before   numeric;
    v_after    numeric;
    v_amt      numeric;
    v_mv       uuid[];
    v_je       jsonb;
    v_out      jsonb := '[]'::jsonb;
BEGIN
    PERFORM require_permission('module.inventory.edit');
    IF p_issued_on IS NULL THEN
        RAISE EXCEPTION 'PART_ISSUE_DATE_REQUIRED';
    END IF;
    IF p_issued_on > v_today THEN
        RAISE EXCEPTION 'PART_ISSUE_DATE_IN_FUTURE|%', p_issued_on;
    END IF;

    SELECT m.id, m.performed_on, m.capitalised, m.capitalised_expense_id, fa.code AS asset_code
      INTO v_maint
      FROM equipment_maintenance m JOIN fixed_assets fa ON fa.id = m.equipment_id
     WHERE m.id = p_maintenance_id
       FOR UPDATE OF m;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'MAINTENANCE_NOT_FOUND|%', COALESCE(p_maintenance_id::text, '?');
    END IF;
    IF v_maint.capitalised OR v_maint.capitalised_expense_id IS NOT NULL THEN
        RAISE EXCEPTION 'PART_ISSUE_CAPITALISED|%|%', v_maint.asset_code, v_maint.performed_on;
    END IF;

    IF p_lines IS NULL OR jsonb_typeof(p_lines) <> 'array' OR jsonb_array_length(p_lines) = 0 THEN
        RAISE EXCEPTION 'PART_ISSUE_NO_LINES';
    END IF;

    -- ① 先把每一条明细判完(按批合计),一行都不写 —— 一张单要么整张出,要么一件都不出
    FOR v_batch, v_qty IN
        SELECT (l ->> 'inbound_batch_id')::uuid, sum((l ->> 'quantity')::numeric)
          FROM jsonb_array_elements(p_lines) l
         GROUP BY 1
    LOOP
        IF v_batch IS NULL THEN
            RAISE EXCEPTION 'PART_ISSUE_NO_BATCH';
        END IF;
        SELECT b.id, b.code, b.unit_price, b.deleted_at, m.kind_code
          INTO v_b
          FROM inbound_batches b JOIN materials m ON m.id = b.material_id
         WHERE b.id = v_batch
           FOR UPDATE OF b;
        IF NOT FOUND OR v_b.deleted_at IS NOT NULL THEN
            RAISE EXCEPTION 'INBOUND_NOT_FOUND|%', v_batch;
        END IF;
        IF v_b.kind_code IS DISTINCT FROM 'spare_part' THEN
            RAISE EXCEPTION 'PART_NOT_SPARE_PART|%|%', v_b.code, COALESCE(v_b.kind_code, '-');
        END IF;
        IF v_qty IS NULL OR v_qty <= 0 THEN
            RAISE EXCEPTION 'PART_QTY_INVALID|%|%', v_b.code, COALESCE(v_qty::text, '?');
        END IF;
        IF v_b.unit_price IS NULL THEN
            RAISE EXCEPTION 'SPARE_PART_UNPRICED|%', v_b.code;
        END IF;
        SELECT COALESCE(sum(qty_delta), 0) INTO v_avail
          FROM inventory_movements WHERE inbound_batch_id = v_batch AND stock_status = 'available';
        IF v_qty > v_avail THEN
            RAISE EXCEPTION 'PART_ISSUE_EXCEEDS_AVAILABLE|%|%|%', v_b.code, v_avail, v_qty;
        END IF;
    END LOOP;
    -- 每一条明细自己的数量也要 > 0(合计 > 0 不等于每一条 > 0)
    IF EXISTS (SELECT 1 FROM jsonb_array_elements(p_lines) l
                WHERE (l ->> 'quantity') IS NULL OR (l ->> 'quantity')::numeric <= 0) THEN
        RAISE EXCEPTION 'PART_QTY_INVALID|-|%',
            (SELECT COALESCE(l ->> 'quantity', '?') FROM jsonb_array_elements(p_lines) l
              WHERE (l ->> 'quantity') IS NULL OR (l ->> 'quantity')::numeric <= 0 LIMIT 1);
    END IF;

    -- ② 逐条写:批次的剩余量 · 流水 · 分录 · 一行出库记录
    PERFORM set_config('evoltrya.part_issue_ctx', 'issue', true);
    FOR v_line IN SELECT * FROM jsonb_array_elements(p_lines)
    LOOP
        v_batch := (v_line ->> 'inbound_batch_id')::uuid;
        v_qty   := (v_line ->> 'quantity')::numeric;
        v_id    := gen_random_uuid();
        SELECT code, remaining_qty INTO v_b FROM inbound_batches WHERE id = v_batch;
        v_before := v_b.remaining_qty;
        v_after  := v_before - v_qty;
        v_cost   := inbound_batch_landed_unit_cost_all(v_batch);

        UPDATE inbound_batches
           SET remaining_qty = v_after, updated_by = v_user, updated_at = now()
         WHERE id = v_batch;
        v_mv := drain_stock(
            p_qty => v_qty, p_movement_type => 'maintenance_issue', p_business_date => p_issued_on,
            p_inbound_batch_id => v_batch, p_statuses => ARRAY['available'],
            p_notes => 'Spare parts to ' || v_maint.asset_code || ' maintenance of ' || v_maint.performed_on,
            p_created_by => v_user);

        v_je := NULL;
        v_amt := round(v_before * COALESCE(v_cost, 0), 2) - round(v_after * COALESCE(v_cost, 0), 2);
        IF v_amt <> 0 THEN
            v_je := post_journal_entry(
                p_issued_on,
                'Spare parts ' || v_b.code || ' to ' || v_maint.asset_code || ' maintenance of ' || v_maint.performed_on,
                'maintenance_part', v_id,
                jsonb_build_array(
                    jsonb_build_object('account_code', '6800', 'side', 'debit',  'currency', base_currency_code(), 'amount_ccy', v_amt),
                    jsonb_build_object('account_code', '1200', 'side', 'credit', 'currency', base_currency_code(), 'amount_ccy', v_amt)));
        END IF;

        INSERT INTO maintenance_part_issues (id, maintenance_id, inbound_batch_id, kind, quantity, business_date,
                                             movement_ids, journal_entry_id, created_by)
        VALUES (v_id, p_maintenance_id, v_batch, 'issue', v_qty, p_issued_on, v_mv, (v_je ->> 'entry_id')::uuid, v_user);

        v_out := v_out || jsonb_build_object('issue_id', v_id, 'batch_code', v_b.code, 'quantity', v_qty,
                                             'journal_code', v_je ->> 'code');
    END LOOP;
    PERFORM set_config('evoltrya.part_issue_ctx', '', true);

    RETURN jsonb_build_object('maintenance_id', p_maintenance_id, 'lines', v_out);
END;
$function$;

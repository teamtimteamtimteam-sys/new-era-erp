-- db/functions/inventory_control_reconciliation.sql
-- INV-VAL-1:存货明细账 ↔ 控制科目的两条腿(1200 原料 / 1220 产成品),
-- 供 gl_control_reconciliation 拼接。四条具名成因 + 两条机制项,【没有兜底桶】。
--
-- ★【归因必须【原分录优先】走回批次】★ 1200 上的冲销分录,它的 source_id
--   指向【原分录】,不是批次。写成 COALESCE(je.source_id, orig.source_id)
--   会让 4 行归因失败 —— 原分录算进了批次、它的冲销没有,净额错成 +原分录,
--   unexplained 当场不为零。正确顺序是 COALESCE(orig.source_id, je.source_id)。
--   实测(2026-08-31):18 行全部归因,归因合计 = 74,687.92 = 1200 的余额本身。
--
-- 【它【不】授给 authenticated】只被 gl_control_reconciliation(属主权限)
--   在体内调用。但它自己仍然 require_permission —— **授权不是控制**。
--
-- NOTE: introduced by db/migrations/2026-08-31-invval1-the-valuation-report-the-close-gate-and-the-fields-already-mandatory.sql.
-- CLEANUP-A fu1:落地成本改读 inbound_batch_landed_unit_cost_all(无判据的过账原语)——
-- 计值不许取决于谁按的按钮。

CREATE OR REPLACE FUNCTION public.inventory_control_reconciliation(p_as_of date)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_sides      jsonb := '[]'::jsonb;
    v_live       boolean;
    v_refuse     text;
    -- raw
    v_led_raw    numeric;
    v_sub_raw    numeric;
    v_c1 numeric; v_c2 numeric; v_c3 numeric; v_c6 numeric;
    v_m3 numeric; v_m4 numeric;
    v_diff_raw   numeric;
    v_unexp_raw  numeric;
    -- fg
    v_led_fg     numeric;
    v_sub_fg     numeric;
    v_fg_pre     numeric;
    v_diff_fg    numeric;
    v_unexp_fg   numeric;
    v_null_bd    integer;
    v_late_cap   integer;
BEGIN
    -- 【定义者函数必须自己问】见抬头第五节:授权不是控制。
    PERFORM require_permission('module.finance.view');
    IF p_as_of IS NULL THEN
        RAISE EXCEPTION 'AS_OF_REQUIRED';
    END IF;

    v_live := (p_as_of >= CURRENT_DATE);

    -- ── 明细侧能不能重建 ────────────────────────────────────────────────
    IF NOT v_live THEN
        SELECT count(*) INTO v_null_bd
          FROM inventory_movements m
         WHERE m.business_date IS NULL;
        SELECT count(*) INTO v_late_cap
          FROM (
            SELECT fa.created_at FROM freight_allocations fa
            UNION ALL
            SELECT bpca.created_at FROM batch_processing_cost_allocations bpca
          ) c
         WHERE c.created_at::date > p_as_of;

        IF v_null_bd > 0 THEN
            v_refuse := 'BUSINESS_DATES_INCOMPLETE|' || v_null_bd
                     || '|' || COALESCE((SELECT min(business_date)::text
                                           FROM inventory_movements
                                          WHERE business_date IS NOT NULL), '?');
        ELSIF v_late_cap > 0 THEN
            v_refuse := 'CAPITALISATION_AFTER_AS_OF|' || v_late_cap;
        END IF;
    END IF;

    -- ── 账面侧:两个科目,as-at 精确(分录带日期,不需要重建) ──────────
    SELECT COALESCE(SUM(l.debit - l.credit), 0) INTO v_led_raw
      FROM journal_activity_lines(NULL, p_as_of, true) l
     WHERE l.account_code = '1200';
    SELECT COALESCE(SUM(l.debit - l.credit), 0) INTO v_led_fg
      FROM journal_activity_lines(NULL, p_as_of, true) l
     WHERE l.account_code = '1220';

    IF v_refuse IS NOT NULL THEN
        -- 【拒绝也要把账面侧报出来】它是算得准的;拒的是明细侧。
        -- reconciled 为 NULL:「答不上来」不是「对不上」。
        v_sides := jsonb_build_array(
            jsonb_build_object(
                'side','inventory_raw','control_account','1200',
                'ledger_base', round(v_led_raw,2),
                'subledger_base', NULL, 'difference_base', NULL,
                'subledger_basis','refused','refusal', v_refuse,
                'variances','[]'::jsonb,
                'unexplained_base', NULL, 'reconciled', NULL),
            jsonb_build_object(
                'side','inventory_fg','control_account','1220',
                'ledger_base', round(v_led_fg,2),
                'subledger_base', NULL, 'difference_base', NULL,
                'subledger_basis','refused','refusal', v_refuse,
                'variances','[]'::jsonb,
                'unexplained_base', NULL, 'reconciled', NULL));
        RETURN v_sides;
    END IF;

    -- ── 明细侧 + 逐批归因 ───────────────────────────────────────────────
    WITH eff AS (
        SELECT COALESCE(o.source_type, je.source_type) AS st,
               COALESCE(o.source_id,   je.source_id)   AS sid,
               (l.debit - l.credit)                    AS amt
          FROM journal_activity_lines(NULL, p_as_of, true) l
          JOIN journal_entries je ON je.id = l.entry_id
          -- 【原分录优先】见抬头:冲销分录的 source_id 指向原分录,不是批次。
          LEFT JOIN journal_entries o ON o.reversed_by = je.id
         WHERE l.account_code = '1200'
    ),
    attr AS (
        SELECT e.sid AS batch_id, e.amt, e.st FROM eff e
         WHERE e.st IN ('purchase','writeoff')
           AND EXISTS (SELECT 1 FROM inbound_batches b WHERE b.id = e.sid)
        UNION ALL
        SELECT pi.inbound_batch_id,
               e.amt * (pi.quantity_consumed * COALESCE(inbound_batch_landed_unit_cost_all(pi.inbound_batch_id),0))
                     / NULLIF(w.tot,0), e.st
          FROM eff e
          JOIN processing_inputs pi ON pi.run_id = e.sid
          JOIN LATERAL (SELECT SUM(p2.quantity_consumed * COALESCE(inbound_batch_landed_unit_cost_all(p2.inbound_batch_id),0)) AS tot
                          FROM processing_inputs p2
                         WHERE p2.run_id = e.sid AND p2.inbound_batch_id IS NOT NULL) w ON true
         WHERE e.st = 'allocation' AND pi.inbound_batch_id IS NOT NULL
        UNION ALL
        SELECT sl.inbound_batch_id,
               e.amt * (sl.counted_qty - sl.book_qty) / NULLIF(w.tot,0), e.st
          FROM eff e
          JOIN stocktake_lines sl ON sl.stocktake_id = e.sid
          JOIN LATERAL (SELECT SUM(s2.counted_qty - s2.book_qty) AS tot
                          FROM stocktake_lines s2
                         WHERE s2.stocktake_id = e.sid AND s2.inbound_batch_id IS NOT NULL) w ON true
         WHERE e.st = 'stocktake' AND sl.inbound_batch_id IS NOT NULL
        UNION ALL
        SELECT fa.inbound_batch_id, e.amt * fa.amount_base / NULLIF(w.tot,0), e.st
          FROM eff e
          JOIN freight_allocations fa ON fa.freight_document_id = e.sid
          JOIN LATERAL (SELECT SUM(f2.amount_base) AS tot FROM freight_allocations f2
                         WHERE f2.freight_document_id = e.sid) w ON true
         WHERE e.st = 'freight'
    ),
    b AS (
        SELECT ib.id,
               round(COALESCE(ib.remaining_qty * inbound_batch_landed_unit_cost_all(ib.id),0),2) AS batch_side,
               round(COALESCE((SELECT SUM(a.amt) FROM attr a WHERE a.batch_id = ib.id),0),2) AS ledger_net,
               COALESCE((SELECT count(*) FROM attr a WHERE a.batch_id = ib.id AND a.st='purchase'),0) AS purch_n,
               round(COALESCE((SELECT SUM(a.amt) FROM attr a WHERE a.batch_id = ib.id AND a.st='purchase'),0),2) AS purch_net,
               EXISTS (SELECT 1 FROM processing_inputs pi
                         JOIN processing_runs r ON r.id = pi.run_id
                        WHERE pi.inbound_batch_id = ib.id AND r.deleted_at IS NULL
                          AND r.status = 'committed' AND r.allocated_at IS NULL) AS unalloc
          FROM inbound_batches ib
    )
    SELECT round(SUM(batch_side),2),
           -- C1:从来没有过计价分录,而批次身上有价 —— 计价早于过账通路。
           round(SUM(CASE WHEN batch_side > 0 AND purch_n = 0 AND ledger_net <= 0
                          THEN batch_side ELSE 0 END),2),
           -- C2:计价分录有过,但净额为零(冲销之后没有按新价补过)。
           round(SUM(CASE WHEN batch_side > 0 AND purch_n > 0 AND purch_net = 0
                          THEN batch_side ELSE 0 END),2),
           -- C3/C5:账面被解除到了【贷方】—— 放出去的钱从来没有进来过。
           round(SUM(CASE WHEN ledger_net < 0 THEN -ledger_net ELSE 0 END),2),
           -- C6/M1:货已消耗,而 1200 还挂着它的成本(已提交、未分摊)。
           round(SUM(CASE WHEN ledger_net > batch_side AND unalloc
                          THEN -(ledger_net - batch_side) ELSE 0 END),2)
      INTO v_sub_raw, v_c1, v_c2, v_c3, v_c6
      FROM b;

    -- M3 LANDED-DENOM:资本化落在【已被部分消耗】的批次上,分母是 quantity,
    -- 于是解除不足,残值搁浅在 1200。今天为零 —— 唯一一笔资本化已回滚。
    SELECT round(COALESCE(SUM(
             bpca.amount_base * (1 - LEAST(ib.remaining_qty / NULLIF(ib.quantity,0), 1))
           ),0),2) INTO v_m3
      FROM batch_processing_cost_allocations bpca
      JOIN inbound_batches ib ON ib.id = bpca.inbound_batch_id
      JOIN processing_runs r ON r.id = bpca.run_id
     WHERE r.deleted_at IS NULL AND r.status <> 'reversed'
       AND ib.remaining_qty < ib.quantity;

    -- M4:运费按过账当刻的 in_stock_ratio 劈分,之后不再重算。
    -- 残差 = 冻结的比例与今天的比例之差。今天为零 —— 唯一一张运费单已冲销。
    SELECT round(COALESCE(SUM(
             fa.amount_base * (fa.in_stock_ratio
               - LEAST(COALESCE(ib.remaining_qty,0) / NULLIF(ib.quantity,0), 1))
           ),0),2) INTO v_m4
      FROM freight_allocations fa
      JOIN inbound_batches ib ON ib.id = fa.inbound_batch_id
      JOIN freight_documents fd ON fd.id = fa.freight_document_id
     WHERE fd.status <> 'reversed' AND fd.deleted_at IS NULL;

    v_diff_raw  := round(v_sub_raw - v_led_raw, 2);
    -- ★ 没有兜底桶:只扣这六项,任何没被分类的来源原样留在 unexplained 里。
    v_unexp_raw := round(v_diff_raw - (v_c1 + v_c2 + v_c3 + v_c6 + v_m3 + v_m4), 2);

    -- ── 产成品侧 ────────────────────────────────────────────────────────
    -- 【三种状态不许长得一样】(R6):有数 / 0.00(卖光了) / NULL(从未分摊)。
    -- 这里只加【有数】的那些;从未分摊的批次不是 0,它们不参与合计,
    -- 由报表侧渲染成 '—' 并单独报量。
    SELECT round(COALESCE(SUM(ob.remaining_qty * po.unit_cost_base),0),2) INTO v_sub_fg
      FROM output_batches ob
      JOIN processing_outputs po ON po.output_batch_id = ob.id
     WHERE ob.deleted_at IS NULL AND ob.remaining_qty > 0
       AND po.unit_cost_base IS NOT NULL;

    -- M10:成本在 1220 通路存在【之前】就分摊掉了 —— 明细里有,总账里一张分录都没有。
    SELECT round(COALESCE(SUM(ob.remaining_qty * po.unit_cost_base),0),2) INTO v_fg_pre
      FROM output_batches ob
      JOIN processing_outputs po ON po.output_batch_id = ob.id
      JOIN processing_runs r ON r.id = po.run_id
     WHERE ob.deleted_at IS NULL AND ob.remaining_qty > 0
       AND po.unit_cost_base IS NOT NULL
       AND NOT EXISTS (
             SELECT 1 FROM journal_activity_lines(NULL, p_as_of, true) l
              JOIN journal_entries je ON je.id = l.entry_id
             WHERE l.account_code = '1220'
               AND je.source_type = 'allocation' AND je.source_id = r.id);

    v_diff_fg  := round(v_sub_fg - v_led_fg, 2);
    v_unexp_fg := round(v_diff_fg - v_fg_pre, 2);

    v_sides := jsonb_build_array(
        jsonb_build_object(
            'side','inventory_raw','control_account','1200',
            'ledger_base',     round(v_led_raw,2),
            'subledger_base',  v_sub_raw,
            'difference_base', v_diff_raw,
            'subledger_basis', CASE WHEN v_live THEN 'live_position' ELSE 'reconstructed' END,
            'refusal', NULL,
            'variances', jsonb_build_array(
                jsonb_build_object('code','never_capitalised','amount_base',v_c1),
                jsonb_build_object('code','orphaned_reprice_delta','amount_base',v_c2),
                jsonb_build_object('code','relief_without_capitalisation','amount_base',v_c3),
                jsonb_build_object('code','unallocated_consumption','amount_base',v_c6),
                jsonb_build_object('code','stranded_capitalisation','amount_base',v_m3),
                jsonb_build_object('code','freight_split_residue','amount_base',v_m4)),
            'unexplained_base', v_unexp_raw,
            'reconciled', (v_unexp_raw = 0)),
        jsonb_build_object(
            'side','inventory_fg','control_account','1220',
            'ledger_base',     round(v_led_fg,2),
            'subledger_base',  v_sub_fg,
            'difference_base', v_diff_fg,
            'subledger_basis', CASE WHEN v_live THEN 'live_position' ELSE 'reconstructed' END,
            'refusal', NULL,
            'variances', jsonb_build_array(
                jsonb_build_object('code','costed_before_1220_path','amount_base',v_fg_pre)),
            'unexplained_base', v_unexp_fg,
            'reconciled', (v_unexp_fg = 0)));

    RETURN v_sides;
END;
$function$;

COMMENT ON FUNCTION public.inventory_control_reconciliation(p_as_of date) IS
    'INV-VAL-1:存货明细账 ↔ 控制科目(1200 原料 / 1220 产成品)的两条腿,供 gl_control_reconciliation 拼接。四条具名成因 + 两条机制项,【没有兜底桶】,判据是 unexplained = 0。归因必须【原分录优先】走回批次 —— 冲销分录的 source_id 指向原分录,取错顺序会让 4 行归因失败、unexplained 当场不为零。as-at 早于今天时先证明重建算得出来(business_date 无空缺、无迟到的资本化),证不出来就【具名拒绝】,数字为 NULL、reconciled 为 NULL —— 答不上来不是对不上。';

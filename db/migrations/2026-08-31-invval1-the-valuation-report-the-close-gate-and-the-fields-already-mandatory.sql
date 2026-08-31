-- INV-VAL-1:存货计值报表 + 成本分摊关账闸 + 两个【本来就已经必填】的字段
--
-- ════════════════════════════════════════════════════════════════════════════
-- 【本刀最重要的一句:委托书的四件事里,有一件【已经建好了】】
--
-- R9 要求"到货日与业务日在收货时成为必填"。实测四条创建路径,四条都已经拒:
--     create_inbound_batch            → ARRIVAL_DATE_REQUIRED   (IOD-2-fu1)
--     receive_inbound_batch_against_po → ARRIVAL_DATE_REQUIRED   (IOD-2-fu1)
--     create_output_batch             → OUTPUT_DATE_REQUIRED    (IOD-2-fu1)
--     commit_processing_run           → PROCESS_DATE_REQUIRED   (产出日取它)
-- 而且 inbound_batches 与 output_batches 【没有 INSERT 策略】,于是那两支 RPC
-- 是唯一入口 —— 拒绝是真的,不是表单层的。
--
-- 【但它只拒得住"建",拒不住"改回空"】这才是本刀在 R9 上真正补的那一件:
--     app/inbound/[id]/edit/actions.ts 直接 UPDATE 表,空字符串写成 NULL,
--     而 RLS 的 UPDATE 策略只问 module.inbound.edit。
-- 于是【收货时必填,收货后可以清掉】—— 一条只在入口站岗的规矩。
-- 本刀把它补成两侧:建的时候必填(既有),改的时候【不许由有变无】(新增)。
--
-- ★【不回填,而且回填在这里是【做不到】的,不只是"不做"】★
-- 线上 16 张进料批里 7 张没有到货日,它们全部早于 IOD-2-fu1。R9 明写不许回填,
-- 理由是"历史的缺失是诚实的"。所以守卫写成【转移守卫】而不是 NOT NULL:
--     · INSERT 带 NULL          → 拒
--     · UPDATE 把非空改成 NULL  → 拒
--     · UPDATE 让 NULL 保持 NULL → 【放行】
-- 最后一条是全部要点:一张历史行仍然可以改它的物料、供应商、备注,而不会被
-- 一条它无法满足的约束锁死。NOT NULL 会当场锁死那 7 张行。
--
-- ════════════════════════════════════════════════════════════════════════════
-- 【勾稽:第三、第四条腿,不是第四张报表】(R1/R2,STEP 2a)
--
-- INV-VAL-0 量到三个估值面已经存在,而缺的是【与总账对得上】的那一个。
-- gl_control_reconciliation 三天前就为 AR/AP 建好了那台机器:as-at 日期、
-- 按来源分名目、**没有兜底桶**、以 unexplained 为判据。本刀加的是两条腿,
-- 不是一台新机器。
--
-- ★★【为什么归因必须从【冲销分录】走回原分录】★★
-- 1200 上 18 行里有 4 行是冲销,而**冲销分录的 source_id 指向的是原分录,
-- 不是批次**。照 COALESCE(je.source_id, orig.source_id) 写会取到冲销自己的
-- source_id —— 实测那 4 行全部归因失败,于是原分录被算进了批次、它的冲销没有,
-- 净额错成 +原分录,unexplained 当场不为零。
-- 正确的顺序是【原分录优先】:COALESCE(orig.source_id, je.source_id)。
-- 实测:18 行全部归因,归因合计 = 74,687.92 = 1200 的余额本身。
--
-- ★★【四条具名成因,没有兜底桶 —— 这是本函数最要紧的一条设计】★★
-- 分类是【穷举式声明】的。一笔手工分录打进 1200、一张只入了一半账的批次,
-- 都【不匹配任何一条谓词】,于是原样留在 unexplained 里,报表当场不勾稽。
-- 一个永远为 0 的判词是装饰,不是检查 —— 这句话是 GLEXPORT-1 写下的,本刀照抄。
--
-- 【实测(2026-08-31,SGD)】
--   inventory_raw  1200:账面 74,687.92,明细 185,703.48,差 111,015.56
--     never_capitalised          +23,300.00  IN-0002/0012,计价早于过账通路
--     orphaned_reprice_delta     +49,312.76  IN-0003 48,000 + IN-0001 1,312.76
--     relief_without_capitalisation +40,444.00  IN-0013 40,000 + IN-0001 444
--     unallocated_consumption     −2,041.20  IN-0152,PROC-0107 已提交未分摊
--     stranded_capitalisation          0.00  M3 LANDED-DENOM,今日为零
--     freight_split_residue            0.00  M4,唯一一张运费单已冲销
--     UNEXPLAINED                      0.00  ✓
--   inventory_fg   1220:账面 134.86,明细 388.20,差 253.34
--     costed_before_1220_path       +253.34  OUT-2026-0007(PROC-2026-0003)
--     UNEXPLAINED                      0.00  ✓
--
-- ════════════════════════════════════════════════════════════════════════════
-- ★【as-at:能答的答,答不了的【具名拒绝】—— 绝不返回一个自信的零】★(R5)
--
-- INV-VAL-0 实测:按 business_date 问"2026-06-30 的存货",今天返回 0.00 ——
-- 不是错误、不是警告,是一个审计师会抄进底稿的数。原因是 business_date 在
-- 106 行流水里空 31 行,而它的最小值是 2026-07-03。
--
-- 所以明细侧分两种:
--   · p_as_of >= 今天 → 用 remaining_qty,【精确】,basis='live_position';
--   · p_as_of <  今天 → 从流水重建,而重建【必须先证明自己算得出来】:
--       范围内有任何一行 business_date 为空  → 拒
--       范围内有任何一笔资本化发生在 as-at 之后 → 拒(单位成本会是今天的口径)
--     两条都过不了就 basis='refused',数字为 NULL,reconciled 为 NULL。
--     **NULL 不是 false**:「答不上来」与「对不上」是两回事,不许长得一样。
--
-- 【它会随数据变好而自己打开】这不是一条永久关闭的路。business_date 补齐、
-- 资本化补上之后,同一支函数就开始作答 —— 一个真闸,不是一句永远为假的判词。
--
-- ════════════════════════════════════════════════════════════════════════════
-- ★【SECURITY DEFINER 必须自己问调用者是谁 ——【授权不是控制】】★(STEP 2e)
--
-- 本刀读的 inbound_batch_landed_unit_cost 是 SECURITY DEFINER,它【直接读基表的
-- unit_price】,绕过 inbound_batches_masked 的 data.view_prices 遮蔽,而且
-- **它自己不做任何权限判断**。它今天安全,靠的只有一件事:它没有授给
-- authenticated(实测 proacl = postgres, service_role)。
--
-- **授权是一个会被下一个人改掉的配置,不是一道控制。** 本刀新建的两支读取器
-- 都自己 require_permission,并且价格侧自己判 data.view_prices —— 即便有人哪天
-- 把那支函数授了出去,这两支也不会因此多透出一分钱。
--
-- 而 operations 与 warehouse 【有 module.inbound.view、没有 data.view_prices】,
-- 那正是 R1 的读者。所以金额列对他们渲染【具名受限】,不是 0.00 ——
-- 本仓库有三次"读不到就返回 0"的前科,那是本段存在的全部理由。
-- ════════════════════════════════════════════════════════════════════════════

BEGIN;

-- ─────────────────────────────────────────────────────────────────────────────
-- 1 · 存货勾稽的两条腿。gl_control_reconciliation 调它,RPT-1 不调。
-- ─────────────────────────────────────────────────────────────────────────────
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
               e.amt * (pi.quantity_consumed * COALESCE(inbound_batch_landed_unit_cost(pi.inbound_batch_id),0))
                     / NULLIF(w.tot,0), e.st
          FROM eff e
          JOIN processing_inputs pi ON pi.run_id = e.sid
          JOIN LATERAL (SELECT SUM(p2.quantity_consumed * COALESCE(inbound_batch_landed_unit_cost(p2.inbound_batch_id),0)) AS tot
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
               round(COALESCE(ib.remaining_qty * inbound_batch_landed_unit_cost(ib.id),0),2) AS batch_side,
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

COMMENT ON FUNCTION public.inventory_control_reconciliation(date) IS
    'INV-VAL-1:存货明细账 ↔ 控制科目(1200 原料 / 1220 产成品)的两条腿,供 gl_control_reconciliation 拼接。四条具名成因 + 两条机制项,【没有兜底桶】,判据是 unexplained = 0。归因必须【原分录优先】走回批次 —— 冲销分录的 source_id 指向原分录,取错顺序会让 4 行归因失败、unexplained 当场不为零。as-at 早于今天时先证明重建算得出来(business_date 无空缺、无迟到的资本化),证不出来就【具名拒绝】,数字为 NULL、reconciled 为 NULL —— 答不上来不是对不上。';

-- ─────────────────────────────────────────────────────────────────────────────
-- 2 · gl_control_reconciliation:AR/AP 两条腿【一个字未动】,后面接上存货两条腿。
--
-- 【为什么给四条腿都加 variances,而不是只给存货加】
-- AR/AP 的三个分项键(origination/settlement/revaluation)是它们自己的名目;
-- 存货的六个名目完全不同。把名目做成【数组】,读的人就不必知道每条腿各有哪些
-- 键 —— 一个通吃的循环即可渲染四条腿。既有的三个键【原样保留】,
-- management_packs 里已经冻下来的包与 CSV 导出因此一行都不用改。
-- ─────────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.gl_control_reconciliation(p_as_of date)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_base      text;
    v_sides     jsonb := '[]'::jsonb;
    v_side      text;
    v_acct      text;
    v_orig_src  text[];
    v_settle_src text[];
    v_ledger    numeric;
    v_orig_led  numeric;
    v_settle_led numeric;
    v_reval_led numeric;
    v_sub       jsonb;
    v_sub_total numeric;
    v_sub_value numeric;
    v_sub_reduce numeric;
    v_diff      numeric;
    v_ov        numeric;
    v_sv        numeric;
    v_unexp     numeric;
BEGIN
    PERFORM require_permission('module.finance.view');
    IF p_as_of IS NULL THEN
        RAISE EXCEPTION 'AS_OF_REQUIRED';
    END IF;
    SELECT code INTO v_base FROM currencies WHERE is_base;

    FOREACH v_side IN ARRAY ARRAY['ar', 'ap'] LOOP
        IF v_side = 'ar' THEN
            v_acct := '1100';
            v_orig_src   := ARRAY['sale', 'invoice'];
            v_settle_src := ARRAY['payment', 'credit_note'];
        ELSE
            v_acct := '2000';
            v_orig_src   := ARRAY['purchase', 'expense', 'freight'];
            v_settle_src := ARRAY['payment', 'prepayment'];
        END IF;

        SELECT COALESCE(SUM(CASE WHEN v_side = 'ar' THEN l.debit - l.credit
                                 ELSE l.credit - l.debit END), 0)
          INTO v_ledger
          FROM journal_activity_lines(NULL, p_as_of, true) l
         WHERE l.account_code = v_acct;

        SELECT COALESCE(SUM(CASE WHEN v_side = 'ar' THEN l.debit - l.credit
                                 ELSE l.credit - l.debit END), 0)
          INTO v_orig_led
          FROM journal_activity_lines(NULL, p_as_of, true) l
         WHERE l.account_code = v_acct AND l.source_type = ANY(v_orig_src);

        SELECT COALESCE(SUM(CASE WHEN v_side = 'ar' THEN l.credit - l.debit
                                 ELSE l.debit - l.credit END), 0)
          INTO v_settle_led
          FROM journal_activity_lines(NULL, p_as_of, true) l
         WHERE l.account_code = v_acct AND l.source_type = ANY(v_settle_src);

        SELECT COALESCE(SUM(CASE WHEN v_side = 'ar' THEN l.debit - l.credit
                                 ELSE l.credit - l.debit END), 0)
          INTO v_reval_led
          FROM journal_activity_lines(NULL, p_as_of, true) l
         WHERE l.account_code = v_acct AND l.source_type = 'revaluation';

        v_sub := CASE WHEN v_side = 'ar' THEN ar_aging_asof(p_as_of)
                                         ELSE ap_aging_asof(p_as_of) END;
        v_sub_total := (v_sub->>'total_open_base')::numeric;

        SELECT COALESCE(SUM(CASE WHEN v_side = 'ar' THEN (r->>'amount_base')::numeric
                                 ELSE (r->>'doc_value_base')::numeric END), 0),
               COALESCE(SUM(CASE WHEN v_side = 'ar'
                                 THEN (r->>'settled_base')::numeric + COALESCE((r->>'credited_base')::numeric, 0)
                                 ELSE (r->>'settled_base')::numeric END), 0)
          INTO v_sub_value, v_sub_reduce
          FROM jsonb_array_elements(v_sub->'rows') r;

        v_diff := round(v_sub_total - v_ledger, 2);
        v_ov   := round(v_sub_value - v_orig_led, 2);
        v_sv   := round(v_settle_led - v_sub_reduce, 2);
        v_unexp := round(v_diff - (v_ov + v_sv - v_reval_led), 2);

        v_sides := v_sides || jsonb_build_object(
            'side',                     v_side,
            'control_account',          v_acct,
            'ledger_base',              round(v_ledger, 2),
            'subledger_base',           round(v_sub_total, 2),
            'difference_base',          v_diff,
            'origination_variance_base', v_ov,
            'settlement_variance_base',  v_sv,
            'revaluation_base',         round(v_reval_led, 2),
            -- INV-VAL-1:名目也做成数组,与存货两条腿同形,好让一个循环渲染四条腿。
            'subledger_basis',          'documents',
            'refusal',                  NULL,
            'variances', jsonb_build_array(
                jsonb_build_object('code','origination','amount_base',v_ov),
                jsonb_build_object('code','settlement','amount_base',v_sv),
                jsonb_build_object('code','revaluation','amount_base', round(-v_reval_led,2))),
            'unexplained_base',          v_unexp,
            'reconciled',                (v_unexp = 0));
    END LOOP;

    -- INV-VAL-1:第三、第四条腿。存货的名目与 AR/AP 完全不同,所以它自己一支函数。
    v_sides := v_sides || inventory_control_reconciliation(p_as_of);

    RETURN jsonb_build_object(
        'as_of',         p_as_of,
        'base_currency', v_base,
        'sides',         v_sides);
END;
$function$;

-- ─────────────────────────────────────────────────────────────────────────────
-- 3 · close_period 的【第五条】拒绝(R8)
--
-- ★【它叫 PROCESSING_COSTS_UNALLOCATED,不叫 INVENTORY_NOT_RECONCILED】★
-- 这个命名是本条闸最要紧的一件事。它检查的只有一件事:已提交、未分摊的加工单。
-- 它【关不住】1200 的其他漂移途径:
--     M3 stranded_capitalisation  —— 分摊【做过了】,闸是绿的,而残值仍搁浅在 1200;
--                                    今天 0.00,**一旦产线真的开动必然不为零**;
--     M4 freight_split_residue    —— 运费按过账当刻的比例劈分,之后不再重算,闸看不见运费;
--     M5 remaining_qty > quantity —— 盘盈使解除【过头】(IN-2026-0003 是 80/50,
--                                    资本化成本会多解除 60%),方向与 M3 【相反】、
--                                    落在【不同批次】上,所以两者【不会互相抵消】;
--     M7 注销/盘点不检查成本是否进过账 —— 放出从未进来的钱。
-- 一条按【结果】命名的闸会宣称一份它并不具备的完整性。所以它按【它检查的那件事】命名。
--
-- 【拒绝里点名那些加工单】第一个撞上它的人会被 8 张八月的测试单挡住,
-- 而补救办法必须从拒绝这句话本身看得出来 —— 否则它就是一堵没有门的墙。
--
-- 【实测会挡住哪些月末(2026-08-31)】
--   2026-06-30 → PROC-2026-0001
--   2026-07-31 → + PROC-2026-0009(该月【已关】,本闸不追溯;重开再关会被拒)
--   2026-08-31 → + 0106/0107/0108/0162/0163/0225,共 8 张 ← 【下一次关账】
-- Tim 已在知情下裁定收进本刀。
-- ─────────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.close_period(p_period_end date, p_notes text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_locked   date;
    v_count    integer;
    v_debits   numeric;
    v_credits  numeric;
    v_new_lock date;
    v_dep      numeric;
    v_run_n    integer;
    v_runs     text;
BEGIN
    PERFORM require_permission('module.finance.edit');
    IF p_period_end IS NULL
       OR p_period_end <> (date_trunc('month', p_period_end) + interval '1 month - 1 day')::date THEN
        RAISE EXCEPTION 'NOT_MONTH_END|%', COALESCE(p_period_end::text, '?');
    END IF;

    SELECT locked_before INTO v_locked FROM finance_settings WHERE id FOR UPDATE;
    IF v_locked IS NOT NULL AND p_period_end < v_locked THEN
        RAISE EXCEPTION 'ALREADY_CLOSED|%', v_locked;
    END IF;

    v_dep := (preview_depreciate_fixed_assets(p_period_end)->>'total_delta')::numeric;
    IF COALESCE(v_dep, 0) > 0 THEN
        RAISE EXCEPTION 'DEPRECIATION_OUTSTANDING|%|%', p_period_end, v_dep;
    END IF;

    -- ★ INV-VAL-1 R8:第五条 —— 已提交但从未分摊成本的加工单挡住关账。
    -- 与折旧那一条同形(都是"这个月还欠着一件必须做完的事"),所以紧挨着它。
    SELECT count(*), string_agg(r.code, ', ' ORDER BY r.process_date, r.code)
      INTO v_run_n, v_runs
      FROM processing_runs r
     WHERE r.deleted_at IS NULL
       AND r.status = 'committed'
       AND r.allocated_at IS NULL
       AND r.process_date <= p_period_end;
    IF COALESCE(v_run_n, 0) > 0 THEN
        RAISE EXCEPTION 'PROCESSING_COSTS_UNALLOCATED|%|%|%', p_period_end, v_run_n, v_runs
          USING HINT = '这些加工单已提交但从未分摊成本 —— 料已经动了,而 1200 还没有被解除。'
                    || '在关账之前把它们分摊掉,或者冲销掉不该存在的那些。';
    END IF;

    SELECT COUNT(DISTINCT jl.entry_id),
           round(COALESCE(SUM(jl.debit), 0), 2),
           round(COALESCE(SUM(jl.credit), 0), 2)
    INTO v_count, v_debits, v_credits
    FROM journal_lines jl
    JOIN journal_entries je ON je.id = jl.entry_id
    WHERE je.entry_date <= p_period_end;

    IF v_debits <> v_credits THEN
        RAISE EXCEPTION 'TRIAL_BALANCE_UNBALANCED|%|%', v_debits, v_credits;
    END IF;

    v_new_lock := p_period_end + 1;

    INSERT INTO period_closes (period_end, notes, entries_count, total_debits, total_credits)
    VALUES (p_period_end, p_notes, v_count, v_debits, v_credits);

    UPDATE finance_settings
    SET locked_before = v_new_lock, updated_by = auth.uid()
    WHERE id;

    RETURN jsonb_build_object(
        'period_end', p_period_end,
        'locked_before', v_new_lock,
        'entries_count', v_count,
        'total_debits', v_debits,
        'total_credits', v_credits
    );
END;
$function$;

-- ─────────────────────────────────────────────────────────────────────────────
-- 4 · RPT-1 快照的金额与库龄两节(R1/R4/R6/R7,STEP 2c/2d/2e)
--
-- ★★【读不到价的人拿到的是【具名受限】,不是一个更小的合计】★★
-- operations 与 warehouse 实测:module.inventory.view = true,
-- data.view_prices = **false**。他们正是 R1 的读者 —— 也就是说,
-- 这张报表最主要的使用者【看不到任何价格】。
-- 本仓库有三次"读取器读不到就返回 0"的前科(FIN-6 的原样重演),
-- 而一个悄悄少算的合计比一个明说"你看不到"的空格坏得多:前者会被抄进决策。
-- 所以金额字段对他们是 **NULL + restriction 具名**,数量字段照常给 ——
-- 数量不是价格,没有理由一起扣下。
--
-- 【库龄:arrival_date 唯一,缺失渲染 '—',绝不是零、绝不是 90 天以上】(R4)
-- 档位取 aging_bucket —— 它是 AGING-1 立的【唯一一处】边界定义(0-30/31-60/
-- 61-90/90+),天数为 NULL 时返回 NULL。lib/valuation.ts 里那份 30/90 的
-- AGING_BANDS 是【第二份定义】,本刀连同 /inventory 一起退休掉它。
-- 线上 4 张在库批次没有到货日,占在库价值的 58.7% —— 它们进 'no_date' 档,
-- 那是一个【被渲染出来的档位】,不是一个被藏起来的。
-- ─────────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.inventory_valuation_snapshot(p_as_of date)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_prices  boolean;
    v_base    text;
    v_loc     jsonb;
    v_age     jsonb;
    v_prod    jsonb;
    v_unpriced_qty numeric;
    v_unpriced_n   integer;
    v_nocost_qty   numeric;
    v_nocost_n     integer;
    v_noloc_n      integer;
    v_mv_n         integer;
    v_unalloc_n    integer;
BEGIN
    -- 【授权不是控制】见抬头第五节:本函数自己判,不靠 EXECUTE 授权收得够窄。
    PERFORM require_permission('module.inventory.view');
    IF p_as_of IS NULL THEN
        RAISE EXCEPTION 'AS_OF_REQUIRED';
    END IF;
    -- R5:任意 as-at 具名拒绝 —— business_date 在 2026-07-03 之前【不存在】,
    -- 照样作答会返回一个自信的 0.00。月末从冻结的管理包里取。
    IF p_as_of < CURRENT_DATE THEN
        RAISE EXCEPTION 'AS_OF_NOT_RECONSTRUCTABLE|%|%', p_as_of,
            COALESCE((SELECT min(business_date)::text FROM inventory_movements
                       WHERE business_date IS NOT NULL), '?')
          USING HINT = '业务日在此之前不完整,历史时点的存货无法重建 —— '
                    || '月末数请从已冻结的管理包里取,不要在今天重算一个历史数字。';
    END IF;

    v_prices := has_permission('data.view_prices');
    SELECT code INTO v_base FROM currencies WHERE is_base;

    -- ── B 节:物料 × 库位 × 状态,复用 RPT-1 的分组与「未指定库位」语义 ──
    SELECT COALESCE(jsonb_agg(x ORDER BY x->>'location_code' NULLS LAST, x->>'material_code'), '[]'::jsonb)
      INTO v_loc
      FROM (
        SELECT jsonb_build_object(
                 'location_id',   mv.location_id,
                 'location_code', sl.code,
                 'location_name', sl.name,
                 'material_code', mt.code,
                 'material_name', mt.name,
                 'unit',          mt.unit,
                 'stock_status',  mv.stock_status,
                 'qty',           SUM(mv.qty_delta),
                 -- 【读不到价 → NULL,不是 0】
                 'value_base', CASE WHEN v_prices THEN
                     round(COALESCE(SUM(mv.qty_delta * inbound_batch_landed_unit_cost(ib.id)), 0), 2)
                     ELSE NULL END,
                 -- 【未计价的量单独报】它不是"值 0 的货",是"没有价的货"。
                 'unpriced_qty', SUM(CASE WHEN inbound_batch_landed_unit_cost(ib.id) IS NULL
                                          THEN mv.qty_delta ELSE 0 END)
               ) AS x
          FROM inventory_movements mv
          JOIN inbound_batches ib ON ib.id = mv.inbound_batch_id
          JOIN materials mt ON mt.id = ib.material_id
          LEFT JOIN storage_locations sl ON sl.id = mv.location_id
         WHERE mt.deleted_at IS NULL AND ib.deleted_at IS NULL
         GROUP BY mv.location_id, sl.code, sl.name, mt.code, mt.name, mt.unit, mv.stock_status
        HAVING SUM(mv.qty_delta) <> 0
      ) s;

    -- ── C 节:库龄。档位取 aging_bucket,缺日期是一个【被渲染的档位】 ──
    SELECT COALESCE(jsonb_agg(x ORDER BY x->>'bucket'), '[]'::jsonb)
      INTO v_age
      FROM (
        SELECT jsonb_build_object(
                 'bucket',  COALESCE(aging_bucket((p_as_of - ib.arrival_date)::integer), 'no_date'),
                 'batches', count(*),
                 'qty',     SUM(ib.remaining_qty),
                 'value_base', CASE WHEN v_prices THEN
                     round(COALESCE(SUM(ib.remaining_qty * inbound_batch_landed_unit_cost(ib.id)), 0), 2)
                     ELSE NULL END
               ) AS x
          FROM inbound_batches ib
         WHERE ib.deleted_at IS NULL AND ib.remaining_qty > 0
         GROUP BY COALESCE(aging_bucket((p_as_of - ib.arrival_date)::integer), 'no_date')
      ) s;

    -- ── 产出侧:三种状态必须长得不一样(R6) ────────────────────────────
    --   有数 / 0.00(计过价,货卖光了) / NULL(从未分摊,'—')
    SELECT jsonb_build_object(
             'on_hand_batches', count(*),
             'on_hand_qty',     COALESCE(SUM(ob.remaining_qty),0),
             'costed_value_base', CASE WHEN v_prices THEN
                 round(COALESCE(SUM(ob.remaining_qty * po.unit_cost_base) FILTER (WHERE po.unit_cost_base IS NOT NULL),0),2)
                 ELSE NULL END,
             'never_costed_batches', count(*) FILTER (WHERE po.unit_cost_base IS NULL),
             'never_costed_qty',     COALESCE(SUM(ob.remaining_qty) FILTER (WHERE po.unit_cost_base IS NULL),0))
      INTO v_prod
      FROM output_batches ob
      LEFT JOIN processing_outputs po ON po.output_batch_id = ob.id
     WHERE ob.deleted_at IS NULL AND ob.remaining_qty > 0;

    -- ── 这张报表看不见什么 —— 逐条具名,不留给读的人猜 ──────────────────
    SELECT COALESCE(SUM(ib.remaining_qty),0), count(*)
      INTO v_unpriced_qty, v_unpriced_n
      FROM inbound_batches ib
     WHERE ib.deleted_at IS NULL AND ib.remaining_qty > 0
       AND inbound_batch_landed_unit_cost(ib.id) IS NULL;
    SELECT COALESCE(SUM(ob.remaining_qty),0), count(*)
      INTO v_nocost_qty, v_nocost_n
      FROM output_batches ob
      LEFT JOIN processing_outputs po ON po.output_batch_id = ob.id
     WHERE ob.deleted_at IS NULL AND ob.remaining_qty > 0 AND po.unit_cost_base IS NULL;
    SELECT count(*) INTO v_noloc_n FROM inventory_movements WHERE location_id IS NULL;
    SELECT count(*) INTO v_mv_n    FROM inventory_movements;
    SELECT count(*) INTO v_unalloc_n FROM processing_runs
     WHERE deleted_at IS NULL AND status='committed' AND allocated_at IS NULL;

    RETURN jsonb_build_object(
        'as_of', p_as_of,
        'base_currency', v_base,
        'basis', 'landed_cost',
        'prices_visible', v_prices,
        -- ★ 具名受限 —— 不是一个更小的合计
        'restriction', CASE WHEN v_prices THEN NULL
                            ELSE 'PRICE_COMPONENTS_RESTRICTED|data.view_prices' END,
        'by_location', v_loc,
        'ageing', v_age,
        'produced', v_prod,
        'cannot_see', jsonb_build_object(
            'unpriced_on_hand_qty',      v_unpriced_qty,
            'unpriced_on_hand_batches',  v_unpriced_n,
            'never_costed_produced_qty', v_nocost_qty,
            'never_costed_produced_batches', v_nocost_n,
            'movements_without_location', v_noloc_n,
            'movements_total',            v_mv_n,
            'committed_runs_unallocated', v_unalloc_n,
            -- 关账闸【关不住】的那四条,连同今天的金额一起写在报表脸上,
            -- 免得有人把 PROCESSING_COSTS_UNALLOCATED 读成"1200 从此不会漂"。
            'close_gate_does_not_cover',
                jsonb_build_array('stranded_capitalisation (M3)',
                                  'freight_split_residue (M4)',
                                  'stocktake_gain_over_relief (M5)',
                                  'relief_without_capitalisation (M7)')));
END;
$function$;

COMMENT ON FUNCTION public.inventory_valuation_snapshot(date) IS
    'INV-VAL-1:RPT-1 快照的金额与库龄两节(物料 × 库位 × 状态 + 库龄档 + 产出三态)。口径是 inbound_batch_landed_unit_cost,与注销/盘点/勾稽同一份定义。★读不到 data.view_prices 的人拿到 value_base = NULL 加一条具名 restriction,【不是一个更小的合计】—— operations 与 warehouse 实测就是这一类,而本仓库有三次"读不到就返回 0"的前科。数量照给:数量不是价格。库龄档取 aging_bucket(AGING-1 的唯一定义),缺到货日进 no_date 档并被渲染出来,不是零、不是 90 天以上。任意历史 as-at 具名拒绝(AS_OF_NOT_RECONSTRUCTABLE):business_date 在 2026-07-03 之前不存在,照答会给出一个自信的 0.00。';

-- ─────────────────────────────────────────────────────────────────────────────
-- 5 · R9 真正缺的那一半:两个日期【不许由有改成无】
--
-- 建的时候四条路径都已经拒(见抬头)。改的时候没有人拦 ——
-- app/inbound/[id]/edit/actions.ts 直接 UPDATE,空串写成 NULL。
--
-- 【为什么是转移守卫,不是 NOT NULL】线上 7 张进料批没有到货日,全部早于
-- IOD-2-fu1,而 R9 明写【不许回填】。NOT NULL 会把那 7 张行锁死:
-- 连改个备注都提交不了。所以只拒【由有变无】,让 NULL 保持 NULL 的更新照过。
-- 历史的缺失因此活了下来,而新的缺失一个也进不来。
-- ─────────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.guard_receipt_date_not_cleared()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO 'public', 'pg_temp'
AS $function$
BEGIN
    IF TG_TABLE_NAME = 'inbound_batches' THEN
        IF NEW.arrival_date IS NULL THEN
            IF TG_OP = 'INSERT' THEN
                RAISE EXCEPTION 'ARRIVAL_DATE_REQUIRED'
                  USING HINT = '到货日在收货时必填(IOD-2-fu1);不给默认值,'
                            || 'CURRENT_DATE 会让留空比填对更容易通过。';
            ELSIF OLD.arrival_date IS NOT NULL THEN
                RAISE EXCEPTION 'ARRIVAL_DATE_REQUIRED|%', OLD.code
                  USING HINT = '这批货已经有到货日了,不能改回空 —— '
                            || '历史上缺失的那些留着,新的缺失不许再产生。';
            END IF;
        END IF;
    ELSE  -- output_batches
        IF NEW.output_date IS NULL THEN
            IF TG_OP = 'INSERT' THEN
                RAISE EXCEPTION 'OUTPUT_DATE_REQUIRED'
                  USING HINT = '产出日在建批时必填(IOD-2-fu1);加工单那条路从 '
                            || 'commit_processing_run 的 p_process_date 取。';
            ELSIF OLD.output_date IS NOT NULL THEN
                RAISE EXCEPTION 'OUTPUT_DATE_REQUIRED|%', OLD.code
                  USING HINT = '这批产出已经有产出日了,不能改回空。';
            END IF;
        END IF;
    END IF;
    RETURN NEW;
END;
$function$;

COMMENT ON FUNCTION public.guard_receipt_date_not_cleared() IS
    'INV-VAL-1 R9:到货日 / 产出日的【转移守卫】。建的时候必填由四支 RPC 各自拒(ARRIVAL_DATE_REQUIRED / OUTPUT_DATE_REQUIRED / PROCESS_DATE_REQUIRED);本守卫补的是它们拦不住的那一半 —— 直接 UPDATE 把已有的日期改回 NULL。【不是 NOT NULL】:线上 7 张进料批没有到货日且 R9 明写不许回填,NOT NULL 会把它们锁到连备注都改不了。只拒由有变无,NULL 保持 NULL 的更新照过。';

DROP TRIGGER IF EXISTS guard_arrival_date_not_cleared ON public.inbound_batches;
CREATE TRIGGER guard_arrival_date_not_cleared
    BEFORE INSERT OR UPDATE ON public.inbound_batches
    FOR EACH ROW EXECUTE FUNCTION public.guard_receipt_date_not_cleared();

DROP TRIGGER IF EXISTS guard_output_date_not_cleared ON public.output_batches;
CREATE TRIGGER guard_output_date_not_cleared
    BEFORE INSERT OR UPDATE ON public.output_batches
    FOR EACH ROW EXECUTE FUNCTION public.guard_receipt_date_not_cleared();

-- ─────────────────────────────────────────────────────────────────────────────
-- 6 · 管理包:整份勾稽本来就冻在里面了(R3)
--
-- ★【R3 的大半在这一刀之前就已经成立,而这值得写清楚】★
-- management_pack_data 已经在调 gl_control_reconciliation(v_aging),并把
-- **整个返回值**原样存进 'control_reconciliation'。所以本刀给勾稽加两条腿之后,
-- 管理包【自动】冻住了存货的账面、明细、每一条具名差异与 unexplained ——
-- 一行都不用改。这正是 GLEXPORT-1 把包做成整块 jsonb 而不是拆成列的回报。
--
-- 本节只补它确实缺的两件:
--   ① unexplained 此前只有一个【合计】。四条腿之后,"有一条腿没解释干净"
--      必须说得出【是哪一条】(4b)。
--   ② SUM 会跳过 NULL,于是一条【被拒绝、根本没评估过】的存货腿会让
--      control_unexplained 显示 false —— 一句假话。拒绝单独记一条(4c)。
--
-- 【已关账的月份会看到什么】v_aging = LEAST(月末, 今天) = 月末(过去),
-- 于是存货明细侧【重建不出来】,这一节冻下来的是一句具名拒绝,
-- 而不是一个今天重算、却摆在历史月份名下的数字。那正是 R3 要的。
-- ─────────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.management_pack_data(p_period_month date)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_start   date;
    v_end     date;
    v_aging   date;
    v_base    text;
    v_locked  date;
    v_is_locked boolean;
    v_pnl     jsonb; v_bs jsonb; v_cf jsonb;
    v_ar      jsonb; v_ap jsonb; v_recon jsonb;
    v_fx      jsonb; v_bank jsonb; v_forecast jsonb;
    v_split   jsonb;
    v_unexp   numeric;
    -- INV-VAL-1:冻下来的记录必须说出【是哪一条腿】没解释干净,
    -- 而不只是「有一条腿」。四条腿之后,一个布尔量已经不够用了。
    v_unexp_sides jsonb;
    v_inv_refused boolean;
    v_inv_refusal text;
BEGIN
    PERFORM require_permission('module.finance.view');
    IF p_period_month IS NULL THEN
        RAISE EXCEPTION 'PACK_PERIOD_REQUIRED';
    END IF;
    v_start := date_trunc('month', p_period_month)::date;
    v_end   := (v_start + INTERVAL '1 month - 1 day')::date;
    -- 【封顶,而不是拒绝】实时预览要能看当月;拒绝会让当月完全看不见,
    -- 而那比"看到截至今天的账龄并被告知它被封顶了"坏。
    v_aging := LEAST(v_end, CURRENT_DATE);

    SELECT code INTO v_base FROM currencies WHERE is_base;
    SELECT locked_before INTO v_locked FROM finance_settings;
    -- 【已关账 = 这个月的每一天都不能再过账】locked_before 是"早于它的都锁了",
    -- 所以判据是 locked_before > period_end,与 file_gst_return 逐字同源。
    v_is_locked := (v_locked IS NOT NULL AND v_locked > v_end);

    -- ── 三张报表:全部是调用 ────────────────────────────────────────────────
    v_pnl := pnl_statement(v_start, v_end);
    v_bs  := balance_sheet(v_end);
    v_cf  := cash_flow_statement(v_start, v_end);

    -- ── 账龄与控制科目勾稽 ──────────────────────────────────────────────────
    v_ar    := ar_aging_asof(v_aging);
    v_ap    := ap_aging_asof(v_aging);
    v_recon := gl_control_reconciliation(v_aging);

    -- ── 月末外币就绪:【读那张视图,不自己判】 ───────────────────────────────
    SELECT COALESCE(jsonb_agg(jsonb_build_object(
               'currency', f.currency, 'has_mid', f.has_mid,
               'mid_rate', f.mid_rate, 'mid_rate_as_of', f.mid_rate_as_of,
               'revalued', f.revalued, 'blocks_close', f.blocks_close) ORDER BY f.currency), '[]'::jsonb)
      INTO v_fx
      FROM fx_month_end_readiness f
     WHERE f.month_end = v_end;

    -- ── 银行对账:这个月有没有对过 ─────────────────────────────────────────
    SELECT COALESCE(jsonb_agg(jsonb_build_object(
               'account_code', bs.bank_account_code, 'statement_code', bs.code,
               'currency', br.currency, 'as_of', br.as_of,
               'bank_closing_balance', br.bank_closing_balance,
               'book_balance', br.book_balance, 'difference', br.difference,
               'reconciled_at', br.reconciled_at) ORDER BY bs.bank_account_code), '[]'::jsonb)
      INTO v_bank
      FROM bank_reconciliations br
      JOIN bank_statements bs ON bs.id = br.statement_id
     WHERE br.as_of BETWEEN v_start AND v_end
       AND br.superseded_at IS NULL;

    -- ── 现金预测:读【冻下来的那一份】,不现算 ──────────────────────────────
    -- 现算会让"这个包里的预测"与"当时那一份"是两个数,而 CASHFLOW-1 冻结它
    -- 的全部理由就是偏差要拿【过去那一份】比。
    SELECT COALESCE(jsonb_agg(jsonb_build_object(
               'code', cfz.code, 'week_start', cfz.week_start,
               'frozen_at', cfz.frozen_at) ORDER BY cfz.week_start), '[]'::jsonb)
      INTO v_forecast
      FROM cash_forecasts cfz
     WHERE cfz.week_start BETWEEN v_start AND v_end
       AND cfz.superseded_at IS NULL;

    -- ── ★【拆散在两个月的冲销对】★ ─────────────────────────────────────────
    -- 一张分录落在本月、而它的冲销件(或它冲销的那一张)落在【别的月】,
    -- 本月的数字就带着一条没有对手的腿。这【不是错】—— 跨期冲销完全合法,
    -- 年结时尤其常见 —— 但它是「这个月怎么看着不对」最可能的答案,
    -- 而对手件的日期只有一个 join 之遥,所以说出来比让人去猜便宜得多。
    -- 【实测:线上就有三对】JE-2027-0001/2/3(2027-09-05)由
    -- JE-2026-0058/59/60(2026-08-20)冲销 —— 于是 2026-08 带着三条没有原件的
    -- 冲销腿,合计对 2000 影响 −3,703.68,而全时段净额恰好是 0。
    SELECT COALESCE(jsonb_agg(jsonb_build_object(
               'entry_code', x.code, 'entry_date', x.entry_date,
               'counterpart_code', x.cp_code, 'counterpart_date', x.cp_date,
               'amount_base', x.amt) ORDER BY x.entry_date, x.code), '[]'::jsonb)
      INTO v_split
      FROM (
        -- 本月的原件,冲销件在别的月
        SELECT o.code, o.entry_date, r.code AS cp_code, r.entry_date AS cp_date,
               (SELECT COALESCE(SUM(jl.debit), 0) FROM journal_lines jl WHERE jl.entry_id = o.id) AS amt
          FROM journal_entries o JOIN journal_entries r ON r.id = o.reversed_by
         WHERE o.entry_date BETWEEN v_start AND v_end
           AND r.entry_date NOT BETWEEN v_start AND v_end
        UNION ALL
        -- 本月的冲销件,原件在别的月
        SELECT r.code, r.entry_date, o.code, o.entry_date,
               (SELECT COALESCE(SUM(jl.debit), 0) FROM journal_lines jl WHERE jl.entry_id = r.id)
          FROM journal_entries o JOIN journal_entries r ON r.id = o.reversed_by
         WHERE r.entry_date BETWEEN v_start AND v_end
           AND o.entry_date NOT BETWEEN v_start AND v_end
      ) x;

    SELECT COALESCE(SUM((s->>'unexplained_base')::numeric), 0) INTO v_unexp
      FROM jsonb_array_elements(v_recon->'sides') s;

    -- ★ INV-VAL-1:【是哪一条腿】。SUM 会把 NULL 跳过去,于是一条【被拒绝、
    -- 根本没评估过】的腿会让 control_unexplained 显示 false —— 那是一句假话。
    -- 所以拒绝单独记一条,不混进"解释干净了"里。
    SELECT COALESCE(jsonb_agg(s->>'side' ORDER BY s->>'side'), '[]'::jsonb)
      INTO v_unexp_sides
      FROM jsonb_array_elements(v_recon->'sides') s
     WHERE (s->>'unexplained_base') IS NOT NULL
       AND (s->>'unexplained_base')::numeric <> 0;

    SELECT bool_or(s->>'subledger_basis' = 'refused'),
           max(s->>'refusal')
      INTO v_inv_refused, v_inv_refusal
      FROM jsonb_array_elements(v_recon->'sides') s
     WHERE s->>'side' LIKE 'inventory%';

    RETURN jsonb_build_object(
        'period_month',  v_start,
        'period_start',  v_start,
        'period_end',    v_end,
        'aging_as_of',   v_aging,
        'generated_on',  CURRENT_DATE,
        'base_currency', v_base,
        'locked_before', v_locked,
        'month_locked',  v_is_locked,
        'pnl',           v_pnl,
        'balance_sheet', v_bs,
        'cash_flow',     v_cf,
        'ar_aging',      v_ar,
        'ap_aging',      v_ap,
        'control_reconciliation', v_recon,
        'fx_month_end',  v_fx,
        'bank_reconciliations', v_bank,
        'cash_forecasts', v_forecast,
        'split_reversal_pairs', v_split,
        -- ★【这个包看不见什么 —— 逐条,而不是留给读的人猜】★
        -- 预测那一刀立的规矩:一份悄悄漏掉一整类东西的报表,是一个会被人当真
        -- 的数字。所以缺席是【具名的】,而且带着它自己的判据。
        'caveats', jsonb_build_object(
            'month_not_locked',        NOT v_is_locked,
            'aging_capped_at_today',   (v_aging < v_end),
            'fx_missing_mid',          EXISTS (SELECT 1 FROM jsonb_array_elements(v_fx) f
                                                WHERE (f->>'has_mid')::boolean IS NOT TRUE),
            'fx_not_revalued',         EXISTS (SELECT 1 FROM jsonb_array_elements(v_fx) f
                                                WHERE (f->>'revalued')::boolean IS NOT TRUE),
            'control_unexplained',     (v_unexp <> 0),
            'control_unexplained_base', v_unexp,
            -- ★ INV-VAL-1(R3/4b):冻结的记录自己说出是哪一条腿没解释干净。
            'control_unexplained_sides', v_unexp_sides,
            -- ★【存货这一节被拒绝了,而拒绝【不是】零】(R3/4c)
            -- 已关账的月份 aging_as_of = 月末(过去),存货明细侧重建不出来,
            -- 于是这一节是一句【具名的拒绝】。它必须与"存货为零"长得完全不一样:
            -- 一个读到 0.00 的人会把它抄进底稿,读到拒绝的人会去问为什么。
            'inventory_section_refused', COALESCE(v_inv_refused, false),
            'inventory_section_refusal', v_inv_refusal,
            'split_reversal_pairs_n',  jsonb_array_length(v_split),
            'no_bank_reconciliation',  (jsonb_array_length(v_bank) = 0),
            'no_cash_forecast',        (jsonb_array_length(v_forecast) = 0)));
END;
$function$
;

-- ─────────────────────────────────────────────────────────────────────────────
-- 7 · EXECUTE 授权
--
-- 【触发器函数必须授给 authenticated】它在【调用者】身份下执行 ——
-- 漏掉这一行,任何 authenticated 的 INSERT/UPDATE 会当场 42501,
-- 而症状是"收货整个坏了",与本刀想做的事毫无关系。
-- 既有先例:guard_period_close_mutation 与 emit_batch_receipt_movement 都授了。
GRANT EXECUTE ON FUNCTION public.guard_receipt_date_not_cleared() TO authenticated;

-- 报表读取器:应用直接调它。
GRANT EXECUTE ON FUNCTION public.inventory_valuation_snapshot(date) TO authenticated;

-- 【inventory_control_reconciliation 【不】授给 authenticated】——
-- 它只被 gl_control_reconciliation(属主权限,postgres)在体内调用,
-- 那条路自带 EXECUTE。不授出去是纵深防御的一层;
-- 但**它自己仍然 require_permission**,因为【授权不是控制】(抬头第五节):
-- 下一个人把它授出去的那天,它也不会因此多透出一分钱。

COMMIT;

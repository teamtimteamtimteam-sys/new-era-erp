-- db/functions/reverse_expense_internal.sql
-- MES-5b-2(2026-10-09,MES-5b Step 0 Q22 · Q24,Tim):【冲销一张费用单的那一段 —— 两个调用方,一份实现】。
--   reverse_expense(冲一张费用单)与 reverse_electricity_allocation(撤回一张电费单)都经它冲费用单与分录:
--   原来写在 reverse_expense 里的那一整段(资本支出的两条规矩、冲分录、镜像费用单、成本退回并当场核对)原样搬到这里,
--   一个字的算术都没改 —— 只是不再问码(调用方问),也不再拒电费分摊的费用单(那一句留在 reverse_expense:分摊那一路正是从这里冲它)。
--   ★ 新加一道(Q24):经付款结过的费用单按名拒 EXPENSE_HAS_SETTLEMENT,冲抵过预付款的按名拒 EXPENSE_HAS_PREPAYMENT_APPLIED ——
--     放在这里而不是放在两个调用方里,于是【每一种】费用单、两条路都过同一道。
--   内层:不是 DEFINER,authenticated 调不到(zzz_function_grants.sql)。
--   reverse_expense 抬头那一段(FIN-22 / EQP-1b-iii / CAPEX-1 的两条规矩与它们的不对称)说的就是这里的算术,读那里。
-- ★ MES-6a-1(2026-10-09,F3 · MES-6a Step 0 Q33 · Q34,Tim):第二个参数从此是【冲销的理由】—— 空白按名拒
--   EXPENSE_REVERSAL_REASON_REQUIRED|<单号>(两个调用方先各自拒过一次;这一道让将来任何一条新路都绕不过它)。
--   理由、时刻与人写在【被冲掉的那一张】上(reversal_reason / reversed_at / reversed_by,与 status 同一句 UPDATE);
--   镜像单的 notes 回到只有 'REVERSAL: <原单号>' 一句机器字 —— 人写的话不再和机器字挤在一列里(AT1D1 那一族)。
--   电费单的撤回传它自己的理由,不加前缀(Q34;分摊那一侧另在 electricity_allocation_reversals.reason 上留一份)。
--
-- NOTE: introduced by db/migrations/2026-10-09-mes5b2-reversals.sql.

CREATE OR REPLACE FUNCTION public.reverse_expense_internal(p_expense_id uuid, p_memo text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_orig        expenses%ROWTYPE;
    v_mirror_id   uuid := gen_random_uuid();
    v_year        integer;
    v_seq         integer;
    v_mirror_code text;
    v_je          jsonb;
    -- EQP-1b-iii:追加模式那一笔的成本明细,以及它挂着的那张资产卡
    v_entry       record;
    v_asset       record;
    v_sum         numeric;   -- 未冲销明细之和(推导出来的那一侧)
    v_after       numeric;   -- 退回之后的表头(被维护的那一侧)
    v_settled     numeric;   -- MES-5b-2:经付款核销掉的(付款币种 = 单据币种)
    v_prepaid     numeric;   -- MES-5b-2:冲抵上去的预付款
    v_reason      text := NULLIF(btrim(COALESCE(p_memo, '')), '');   -- MES-6a-1(F3):冲销的理由
BEGIN
    SELECT * INTO v_orig FROM expenses WHERE id = p_expense_id FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'EXPENSE_NOT_FOUND|%', p_expense_id;
    END IF;
    IF v_reason IS NULL THEN
        RAISE EXCEPTION 'EXPENSE_REVERSAL_REASON_REQUIRED|%', v_orig.code
          USING HINT = '没有理由的冲销,事后没人答得出为什么';
    END IF;
    IF v_orig.status <> 'posted' OR v_orig.reversed_by_expense IS NOT NULL THEN
        RAISE EXCEPTION 'EXPENSE_ALREADY_REVERSED|%', v_orig.code;
    END IF;
    -- FIN-22:挂着固定资产台账行的资本性支出不许冲销 —— 冲掉它会留下无对价的
    -- 资产(或者说资产背后那笔应付蒸发)。先处置资产,或走人工分录改正。
    IF EXISTS (SELECT 1 FROM fixed_assets fa WHERE fa.expense_id = p_expense_id) THEN
        RAISE EXCEPTION 'EXPENSE_HAS_ASSET|%', v_orig.code;
    END IF;
    -- ★ MES-5b-2(2026-10-09,MES-5b Step 0 Q24,Tim):【经付款结过的费用单不许冲】—— 每一种费用单都一样(普通、报销、医疗、冲抵、电费分摊、资本)。
    --   冲掉它,应付清单上那一行消失,而指着它的核销行原样留着:2000 借方多出那笔钱、清单读 0,差额落进 list_ledger_reconciliation
    --   的 unexplained(Step 0 §1.4)。先经付款冲销申请把那笔付款冲掉,再冲这张单 —— reverse_freight_document 的 FREIGHT_HAS_SETTLEMENT 先例。
    --   ★ 预付款冲抵同一个形状(ap_open_items 把它算作已结):冲抵一经落下就不可改(prepayment_applications 不可变),没有撤回它的路,
    --   所以这里同样按名拒,并在 docs/known-issues.md 记下(MES5B2-PREPAYMENT-APPLIED-EXPENSE-NOT-REVERSIBLE)。
    SELECT COALESCE(sum(pa.allocated_ccy), 0) INTO v_settled
      FROM payment_allocations pa JOIN payments p ON p.id = pa.payment_id AND p.status = 'posted'
     WHERE pa.expense_id = p_expense_id;
    IF v_settled > 0 THEN
        RAISE EXCEPTION 'EXPENSE_HAS_SETTLEMENT|%|%|%', v_orig.code, v_settled, v_orig.currency
          USING HINT = '这张费用单已经经付款结过 —— 先经付款冲销申请冲掉那笔付款,再冲销这张单';
    END IF;
    SELECT COALESCE(sum(ppa.amount_base), 0) INTO v_prepaid FROM prepayment_applications ppa WHERE ppa.expense_id = p_expense_id;
    IF v_prepaid > 0 THEN
        RAISE EXCEPTION 'EXPENSE_HAS_PREPAYMENT_APPLIED|%|%', v_orig.code, v_prepaid
          USING HINT = '这张费用单上冲抵过预付款,而冲抵撤不回 —— 冲销它会让应付清单与 2000 对不上';
    END IF;

    -- ════════════════════════════════════════════════════════════════════════
    -- EQP-1b-iii:【追加模式】的资本支出 —— 冲销它必须把成本退回去。
    -- 上面那条 FIN-22 的守卫只认【建卡的那一笔】(fixed_assets.expense_id),
    -- 追加进来的每一笔(运费、关税、安装,以及设备发票本身)都不是任何一张卡的
    -- 出生证,所以一律冲得掉 —— 而分录冲掉了、cost_base 却原样不动。
    -- 实测(EQP-1b-ii 的回滚探针):100,000 → 100,000,明细 2 行 → 2 行。
    -- 总账从此与台账不一致,而【折旧读的是台账】。
    --
    -- 【为什么这里不加一列"这条明细已冲销"】那件事已经记在 expenses.status 上了,
    -- 而 fixed_asset_cost_entries 对 expense_id 是 UNIQUE —— 一条明细对一笔支出,
    -- 所以"这条明细还算不算数"= "它那笔支出冲了没有",一个事实一个地方。
    -- 本仓库对"已冲销"的既有写法正是这样一个 JOIN(ap_open_items 与
    -- apply_prepayment 都是),invoice_lines 那个冗余列是被【部分索引的 WHERE
    -- 引用不了另一张表】逼出来的,这里没有那个约束,也就不该抄那半代价。
    SELECT fce.id AS entry_id, fce.asset_id, fce.amount_base
      INTO v_entry
      FROM fixed_asset_cost_entries fce
     WHERE fce.expense_id = p_expense_id;

    IF FOUND THEN
        SELECT fa.code, fa.in_service_date, fa.status AS asset_status
          INTO v_asset
          FROM fixed_assets fa
         WHERE fa.id = v_entry.asset_id
           FOR UPDATE;

        -- 【与 record_expense 同一个铰链,方向相反】那边拒绝往已投用的资产上
        -- 【加】钱(ASSET_ALREADY_IN_SERVICE),理由是"已经提过的那几期会全错,
        -- 而它们已经过账、可能已经锁进期间"。【减】钱撞的是同一堵墙,所以判据
        -- 用同一句 in_service_date IS NOT NULL —— 一个铰链管两个方向。
        -- 【为什么不改成"提过折旧没有"】那是【第二个、更晚】的事实:一台已投用
        -- 但月结还没跑的资产会因此今天准冲、明天不准,而资产本身什么都没变;
        -- 而且加钱那边照旧拒,两个方向就不对称了。一个可判定的规则,不是两个。
        -- 【码另起一个,不复用 ASSET_ALREADY_IN_SERVICE】动作不同、话也不同:
        -- 那一句讲的是"投用后的追加是一次会计判断",对冲销是答非所问。
        IF v_asset.in_service_date IS NOT NULL THEN
            RAISE EXCEPTION 'ASSET_IN_SERVICE_COST_LOCKED|%|%|%',
                v_orig.code, v_asset.code, v_asset.in_service_date
              USING HINT = '这台资产已经投用,它的成本不能再被冲回 —— 这需要一次财务上的裁定';
        END IF;
    END IF;

    -- 冲其分录(冲销日 = 今天;期间锁在 post_journal_entry 内生效)
    -- AP-RECON-1 Batch B:冲销日 = 今天与原分录日里较晚的那个(reversal_date_for;冲销不许早于原分录)
    v_je := reverse_journal_entry_internal(v_orig.journal_entry_id, reversal_date_for(v_orig.journal_entry_id), 'Expense reversal ' || v_orig.code);

    -- 镜像开支单(同形状、status 'posted'、挂冲销分录、不带核销行)。
    -- 镜像行只是冲销的记录凭证,不是新的应付单据 —— ap_open_items 里按
    -- "被别的开支单指为 reversed_by_expense" 排除它。
    v_year := EXTRACT(YEAR FROM CURRENT_DATE)::integer;
    PERFORM pg_advisory_xact_lock(hashtext('expense_code_' || v_year::text)::bigint);
    SELECT COALESCE(MAX(split_part(code, '-', 3)::integer), 0) + 1
    INTO v_seq
    FROM expenses
    WHERE code LIKE document_type_prefix('expense') || '-' || v_year::text || '-%';
    v_mirror_code := document_type_prefix('expense') || '-' || v_year::text || '-' || LPAD(v_seq::text, 4, '0');

    -- 【EQP-1b-iii · D3:employee_id 要抄,purchase_order_line_id 【不要】抄】
    -- 抄 employee_id:PAYEE-1a 加了这一列并放宽了 expenses_counterparty_shape
    -- (unpaid 必须【恰好】挂一个往来对象),但镜像 INSERT 没跟着改 —— 于是冲销
    -- 一张【欠员工】的报销单会撞出一条裸的 CHECK 违例。这是那一列缺席造成的,
    -- 不是别的。
    -- 不抄 purchase_order_line_id:镜像单是【记录凭证】,不是第二张账单。它一带上
    -- 那一列就会立刻重新占住那条采购单行,而"冲销之后行重新可计费"是 EQP-1b-ii
    -- 明文的行为(fixture 105 的 F3③ 钉着它)。那一列的列注释里点名交代过这件事,
    -- 交代的对象就是这一刀 —— 所以这里把两句话并排写下:一列抄,一列不抄。
    -- 【已逐列核对过一遍,不是只看这两列】expenses 共 20 列,镜像显式写 15 列;
    -- 另外 5 列:status(默认 posted,镜像是在册凭证)、reversed_by_expense(NULL,
    -- 镜像自己没被冲)、created_at(now())——三条都是有意的;employee_id 是唯一
    -- 的漏抄;purchase_order_line_id 是唯一有意不抄的。
    INSERT INTO expenses (id, code, expense_date, account_code, amount_ccy, currency, fx_rate,
                          amount_base, payment_status, bank_account_code, supplier_id,
                          employee_id,
                          payee_name, notes, journal_entry_id, created_by)
    VALUES (v_mirror_id, v_mirror_code, CURRENT_DATE, v_orig.account_code,
            v_orig.amount_ccy, v_orig.currency, v_orig.fx_rate, v_orig.amount_base,
            v_orig.payment_status, v_orig.bank_account_code, v_orig.supplier_id,
            v_orig.employee_id,
            v_orig.payee_name,
            'REVERSAL: ' || v_orig.code,
            (v_je->>'reversal_id')::uuid, auth.uid());

    UPDATE expenses
    SET status = 'reversed', reversed_by_expense = v_mirror_id,
        reversal_reason = v_reason, reversed_at = now(), reversed_by = auth.uid()
    WHERE id = p_expense_id;

    -- ── EQP-1b-iii:把成本退回去,并【当场核对】──────────────────────────────
    -- 顺序要紧:上面那句 UPDATE 已经把原单置为 reversed,所以下面那个求和
    -- 【天然排除】了它 —— 判据读的是"未冲销明细之和",不是"减掉一笔之后应该是多少"。
    IF v_entry.entry_id IS NOT NULL THEN
        UPDATE fixed_assets
           SET cost_base = cost_base - v_entry.amount_base
         WHERE id = v_entry.asset_id
        RETURNING cost_base INTO v_after;

        -- 【两侧能不能分开动?能 —— 所以这是一条真检查,不是装饰】
        -- 左边是被 record_expense 逐笔累加维护的表头(一个缓存);
        -- 右边是从明细现算的和。两者由不同的代码路径产生,drift 是可能的,
        -- 而这正是 OPS-17 对 ties/balanced 那类自检提的那个问题:
        -- "要怎样它们才会不相等?" —— 这里答得出来。
        SELECT COALESCE(SUM(fce.amount_base), 0) INTO v_sum
          FROM fixed_asset_cost_entries fce
          JOIN expenses e ON e.id = fce.expense_id
         WHERE fce.asset_id = v_entry.asset_id
           AND e.status = 'posted';

        IF v_after <> v_sum THEN
            RAISE EXCEPTION 'ASSET_COST_LEDGER_DIVERGED|%|%|%',
                v_asset.code, v_after, v_sum;
        END IF;
    END IF;

    -- 【两条 CHECK 都不会被这次减法撞到,而这是可以证明的,不是碰巧】
    --   fixed_assets_cost_base_check      cost_base > 0
    --   fixed_assets_residual_below_cost  residual_base < cost_base
    -- 能被冲销的只有【追加】那些笔(建卡那一笔由 EXPENSE_HAS_ASSET 拦着),
    -- 而 residual_base 只在建卡时写入一次(全库只有 record_expense 写它),
    -- 当时就校验过 residual < 建卡金额。把追加全部冲光,表头也还剩建卡金额,
    -- 于是 cost_base ≥ 建卡金额 > residual_base ≥ 0,两条恒成立。
    RETURN jsonb_build_object(
        'reversal_expense_id', v_mirror_id,
        'code', v_mirror_code,
        'journal_code', v_je->>'code',
        'reversal_journal_id', v_je->>'reversal_id',
        'asset_id', v_entry.asset_id,
        'asset_cost_base_after', v_after,
        'reversal_reason', v_reason
    );
END;
$function$;

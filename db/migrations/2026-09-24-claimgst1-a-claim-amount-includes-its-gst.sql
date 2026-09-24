-- CLAIM-GST-1(2026-09-24):员工报销的金额是收据上的总额 —— 税从里面【拆出来】,不加在上面。
--
-- 【缺陷】decide_expense_claim 与 pay_medical_claim 把员工报的数当【净额】传给 record_expense,
-- 带 TX / BL 码时 record_expense 再在上面加 9%。员工报的是收据总额,已含 GST:
--   CLM-2026-0002 报 100 → EXP-2026-0007 欠 109(9.00 进 1400);
--   MC-2026-0001  报 30  → EXP-2026-0008 欠 32.70(2.70 进 6120,BL)。
-- 两笔按 Tim CLAIM-GST-1 Q6 留作测试数据残留,不改(docs/known-wrong-until-cutover.md)。
--
-- 【修法(Tim CLAIM-GST-1 Q1–Q5)】
--   1. 新函数 tax_included_in(总额, 税率) = round(总额 × 税率 / (100 + 税率), 2) —— IRAS 的税分数;
--      净额 = 总额 − 税,于是 净 + 税 恒等于 总额。
--   2. record_expense 加末位参数 p_amount_includes_tax boolean DEFAULT false(换签名 → 先 DROP)。
--      只有两条报销路传 true;费用表单与供应商账单仍是净额 + 税另算,逐字节不变。
--   3. expenses.tax_ccy:过账时那条 'GST on …' 贷方腿的原币金额。因为拆出来的税不一定等于
--      tax_amount_for(净额)(9% 时约 8.3% 的总额写不成 净 + round(净 × 9%)),读者不能再重算。
--      既有行从各自分录里那条腿回填,并断言它逐行等于此前的算式。
--   4. 五个读者改读 amount_ccy + tax_ccy:ap_open_items · ap_aging_asof · record_payment_internal ·
--      apply_prepayment · expense_claim_status。expense_payable_ccy 删掉。
--   5. 屏幕要说得出总额被拆成了什么(Tim Q7):expense_claim_status 末尾追加 expense_net_ccy /
--      expense_tax_ccy,medical_claim_status 末尾追加 expense_tax_base。只追加,不动既有列序。
--
-- 【落地那一刻线上什么变】总账一分不动(0 张新分录);清单一分不动 —— 回填的 tax_ccy 逐行等于
-- 此前 expense_payable_ccy 算出的那一笔,所以 ap_open_items 的每一行在迁移前后相同。
-- 变的只是【以后】批准的报销:CLM-2026-0004(SGD 1,000,待决)批准时记 917.43 + 82.57(TX)。
--
-- 每一个函数/视图都从它的镜像原样取来(视图改成 CREATE OR REPLACE —— 列集一字未动)。

BEGIN;

-- ═══ db/tables/expenses.sql(末尾 CLAIM-GST-1 那一段)═══
ALTER TABLE public.expenses
    ADD COLUMN tax_ccy numeric NOT NULL DEFAULT 0;

-- 【回填:从分录里那条 'GST on <code>' 贷方腿】expenses 是不可变表(trg_expenses_immutable
-- 只放行 过账→冲销),所以回填期间在【本事务内】关掉那一个守卫,回填完立刻打开 ——
-- 与 FIN-2 回填 payment_allocations 同一个做法。事务失败则连同关掉守卫一起回滚。
ALTER TABLE public.expenses DISABLE TRIGGER trg_expenses_immutable;
UPDATE public.expenses e
   SET tax_ccy = jl.amount_ccy
  FROM public.journal_lines jl
 WHERE jl.entry_id = e.journal_entry_id
   AND jl.credit > 0
   AND jl.line_memo = 'GST on ' || e.code;
ALTER TABLE public.expenses ENABLE TRIGGER trg_expenses_immutable;

-- 【断言回填是对的,而不是只断言它跑过了】三件事,任一不成立整支回滚:
--   ① 带税码且税率 > 0 的每一行都回填到了(否则那一行的应付额会少掉它的税);
--   ② 回填值逐行等于此前读者用的算式 tax_amount_for(amount_ccy, tax_rate_pct) ——
--      于是 ap_open_items 等五个读者在迁移前后逐行相同(这一刀不动任何既有清单数);
--   ③ 回填值折本位币逐行等于落库的 tax_base。
DO $$
DECLARE
    v_taxed   integer;
    v_filled  integer;
    v_bad_old integer;
    v_bad_base integer;
    v_stray   integer;
BEGIN
    SELECT count(*) FILTER (WHERE tax_code IS NOT NULL AND tax_rate_pct > 0),
           count(*) FILTER (WHERE tax_code IS NOT NULL AND tax_rate_pct > 0 AND tax_ccy > 0),
           count(*) FILTER (WHERE tax_code IS NOT NULL
                              AND tax_ccy IS DISTINCT FROM tax_amount_for(amount_ccy, tax_rate_pct)),
           count(*) FILTER (WHERE round(tax_ccy * fx_rate, 2) <> tax_base),
           count(*) FILTER (WHERE tax_code IS NULL AND tax_ccy <> 0)
      INTO v_taxed, v_filled, v_bad_old, v_bad_base, v_stray
      FROM public.expenses;
    IF v_filled <> v_taxed OR v_bad_old <> 0 OR v_bad_base <> 0 OR v_stray <> 0 THEN
        RAISE EXCEPTION 'CLAIMGST1_BACKFILL|taxed=%|filled=%|differs_from_old_formula=%|differs_from_tax_base=%|untaxed_nonzero=%',
            v_taxed, v_filled, v_bad_old, v_bad_base, v_stray;
    END IF;
    RAISE NOTICE 'CLAIM-GST-1 回填:带税 % 行,全部回填,逐行等于旧算式与 tax_base', v_taxed;
END $$;

ALTER TABLE public.expenses
    ADD CONSTRAINT expenses_tax_ccy_shape CHECK (
        (tax_code IS NULL AND tax_ccy = 0)
     OR (tax_code IS NOT NULL AND tax_ccy >= 0));

COMMENT ON COLUMN public.expenses.tax_ccy IS
'CLAIM-GST-1:本单过账时记下的进项税,以【单据币种】计 —— 就是 record_expense 贷 2000 的那条
''GST on EXP-…'' 腿的原币金额。应付额 = amount_ccy + tax_ccy,清单(ap_open_items)、账龄、
付款上限、预付冲抵上限、报销单"付清了没有"都读它。

【为什么存,而不是像 AP-RECON-1 那样用 tax_amount_for(amount_ccy, tax_rate_pct) 算回来】
报销单与医疗申报的金额是【收据上的总额】,税是从里面【拆出来】的(tax_included_in:
税 = round(总额 × 税率 / (100 + 税率), 2),净额 = 总额 − 税)。而拆出来的税【不一定】等于
tax_amount_for(净额):9% 时约 8.3% 的总额写不成 净 + round(净 × 9%)(10.11 → 9.28 + 0.83,
而 tax_amount_for(9.28) = 0.84)。重算会让清单比总账多一分钱。所以这里存下过账用的那一个数,
读者读它 —— 一份数,不是两份算术。

【既有行】由 CLAIM-GST-1 迁移从各自分录里那条 ''GST on <code>'' 贷方腿回填(当时 3 行,
逐行等于 tax_amount_for(amount_ccy, tax_rate_pct),迁移里断言过);冲销镜像单不带税码,为 0。';

-- ═══ db/functions/tax_included_in.sql ═══
CREATE OR REPLACE FUNCTION public.tax_included_in(p_gross numeric, p_rate_pct numeric)
 RETURNS numeric
 LANGUAGE sql
 IMMUTABLE
AS $function$
    SELECT round(p_gross * p_rate_pct / (100.0 + p_rate_pct), 2)
$function$;

-- ═══ db/functions/record_expense.sql ═══
-- 【先 DROP:加参数就是换签名】CREATE OR REPLACE 会留下一个旧重载(FIN-21;preflight 按名拒)。
-- GST-2 / WHT-1 / CAPEX-1 加参数时都走这一步。授权由 apply_migration.sh 在同一事务里重放。
DROP FUNCTION IF EXISTS public.record_expense(date, text, numeric, text, numeric, text, text, uuid, text, text, jsonb, uuid, uuid, text, text, numeric, text, uuid);

CREATE OR REPLACE FUNCTION public.record_expense(p_expense_date date, p_account_code text, p_amount numeric, p_currency text, p_fx_rate numeric DEFAULT NULL::numeric, p_payment_status text DEFAULT 'unpaid'::text, p_bank_account text DEFAULT NULL::text, p_supplier_id uuid DEFAULT NULL::uuid, p_payee_name text DEFAULT NULL::text, p_notes text DEFAULT NULL::text, p_asset jsonb DEFAULT NULL::jsonb, p_employee_id uuid DEFAULT NULL::uuid, p_purchase_order_line uuid DEFAULT NULL::uuid, p_tax_code text DEFAULT NULL::text, p_wht_nature text DEFAULT NULL::text, p_wht_rate_pct numeric DEFAULT NULL::numeric, p_wht_treaty_ref text DEFAULT NULL::text, p_maintenance_id uuid DEFAULT NULL::uuid, p_amount_includes_tax boolean DEFAULT false)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_user       uuid := auth.uid();
    v_account    record;
    v_fx         numeric;
    v_amount_base numeric;
    v_net        numeric;   -- CLAIM-GST-1:这张单的【不含税净额】—— 落进 amount_ccy 的那一个
    v_bank       text;
    v_expense_id uuid := gen_random_uuid();
    v_year       integer;
    v_seq        integer;
    v_code       text;
    v_je         jsonb;
    v_asset_id   uuid;
    v_append_id  uuid;   -- FA-1a:追加模式的目标资产
    v_target     fixed_assets%ROWTYPE;
    -- ── CAPEX-1 ──────────────────────────────────────────────────────────
    v_maint      equipment_maintenance%ROWTYPE;  -- 那条【说了这是资本化】的维修记录
    v_anchor_from date;    -- 新锚点从哪个月起
    v_prev       record;   -- 现行锚点(可能没有 —— 那就是首次资本化)
    v_pre_target numeric;  -- 锚点之前那一段的累计目标(存下来的常数)
    v_prev_start date;     -- 现行那一段是从哪天起算的
    v_prev_rem   numeric;  -- 现行那一段还剩几个月
    v_rem        numeric;  -- 新锚点剩几个月
    v_asset_code text;
    v_life       integer;
    v_residual   numeric;
    v_in_service date;
    v_poline     record;   -- EQP-1b-ii:这笔支出付的那一条采购单行
    v_poline_po  record;   -- 那一行所属的采购单
    v_billed     text;     -- 该行上已有的、【未冲销的】支出编号
    -- ── GST-2 ────────────────────────────────────────────────────────────
    v_tax_code   text;      -- 解析出来的进项税码(未注册时恒 NULL)
    v_tax_rate   numeric := 0;
    v_tax_ccy    numeric := 0;   -- 本单进项税,【单据币种】
    v_tax_base   numeric := 0;   -- 同上,本位币 —— 落库的那一个
    v_claimable  boolean := false;
    v_sup_default text;
    v_jlines     jsonb;
    v_cost_ccy   numeric;   -- 资本化口径:净额 + 【不可抵】的那笔税
    v_cost_base  numeric;
    -- ── WHT-1 ────────────────────────────────────────────────────────────
    v_residence     text;      -- 收款人【此刻】的税务居民身份,抄一份冻进这张单
    v_wht_nature    text;      -- 这笔款在预提税上是什么('none' = 显式的否)
    v_wht_rate      numeric;   -- 实际适用税率(条约减免后)
    v_wht_statutory numeric;   -- 当天的法定税率 —— 减免的上限
    v_wht_ccy       numeric := 0;  -- 全额结清时会代扣多少(单据币种,预期值)
    v_wht_ref       text;
BEGIN
    PERFORM require_permission('module.finance.edit');
    -- 1. 科目:必须存在、启用,且是 expense 类型(只有 6xxx 是合法开支落点)
    IF p_expense_date IS NULL THEN
        RAISE EXCEPTION 'JE_LINE_INVALID|entry_date';
    END IF;
    -- AP-RECON-1 Batch B(Tim AP-RECON-1 Q7):一张费用单记的是【已经发生】的供应,日期晚于今天按名拒。
    IF p_expense_date > CURRENT_DATE THEN
        RAISE EXCEPTION 'DOCUMENT_DATE_IN_FUTURE|expense|%|%', p_expense_date, CURRENT_DATE;
    END IF;
    SELECT code, is_active, account_type INTO v_account
    FROM accounts WHERE code = p_account_code;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'ACCOUNT_NOT_FOUND|%', COALESCE(p_account_code, '?');
    END IF;
    IF NOT v_account.is_active THEN
        RAISE EXCEPTION 'ACCOUNT_INACTIVE|%', v_account.code;
    END IF;
    -- FIN-22:资本性支出 —— 科目 1500 与 p_asset【互相要求】。
    --   * 1500 而无 p_asset:这条路上不许出现没有台账行的固定资产借方;
    --   * p_asset 而非 1500:资本标记只有一个落点,别的科目不接受;
    --   * 其余科目照旧只认 expense 类型("只有 6xxx 是合法开支落点"的原规矩)。
    IF p_account_code = '1500' THEN
        IF p_asset IS NULL THEN
            RAISE EXCEPTION 'CAPITAL_REQUIRES_ASSET|1500';
        END IF;
    ELSIF p_asset IS NOT NULL THEN
        RAISE EXCEPTION 'ASSET_REQUIRES_CAPITAL_ACCOUNT|%', v_account.code;
    ELSIF v_account.account_type <> 'expense' THEN
        RAISE EXCEPTION 'ACCOUNT_NOT_EXPENSE|%', v_account.code;
    END IF;

    -- ════════════════════════════════════════════════════════════════════════
    -- EQP-1b-ii:这笔支出付的是【哪一条采购单行】。
    -- 整块只在 p_purchase_order_line 非空时生效 —— 绝大多数支出根本没有采购单
    -- (D1 那个可空就是为它们留的);而运保关税、安装、调试按 D5 挂在【资产】上
    -- 走追加模式,【不带】采购单行。列注释把这两句话写在了数据库里。
    -- ════════════════════════════════════════════════════════════════════════
    IF p_purchase_order_line IS NOT NULL THEN
        SELECT l.id, l.line_no, l.asset_id, l.purchase_order_id
        INTO v_poline
        FROM purchase_order_lines l
        WHERE l.id = p_purchase_order_line;
        IF NOT FOUND THEN
            RAISE EXCEPTION 'PO_LINE_NOT_FOUND|%', p_purchase_order_line;
        END IF;

        -- ── D2:与 apply_prepayment 同形的三条单据守卫 ────────────────────────
        -- 【"存在"= 没有被软删】apply_prepayment 的那句 WHERE 也带着 deleted_at,
        -- 照抄它是刻意的:少了这一句,一张已被软删的采购单照样收得下账单。
        SELECT po.id, po.code, po.supplier_id, po.status, po.approval_status
        INTO v_poline_po
        FROM purchase_orders po
        WHERE po.id = v_poline.purchase_order_id AND po.deleted_at IS NULL;
        IF NOT FOUND THEN
            RAISE EXCEPTION 'PO_NOT_FOUND|%', v_poline.purchase_order_id;
        END IF;
        IF v_poline_po.status = 'cancelled' THEN
            RAISE EXCEPTION 'PO_CANCELLED|%', v_poline_po.code;
        END IF;
        IF v_poline_po.approval_status <> 'approved' THEN
            RAISE EXCEPTION 'PO_NOT_APPROVED|%|%', v_poline_po.code, v_poline_po.approval_status;
        END IF;

        -- ── D3 上半:这条链接只在【设备行】上成立 ────────────────────────────
        -- 材料行经【收货】计价形成应付(reprice_inbound_batch),而收货量就是
        -- 它的计费上限。让费用单也挂得上去,等于给材料开【第二条计费路】,
        -- 而没有任何东西把这两条对得起来。同一条规矩也在表上(见下面那个触发器)。
        IF v_poline.asset_id IS NULL THEN
            RAISE EXCEPTION 'PO_LINE_NOT_EQUIPMENT|%', v_poline.line_no
              USING HINT = '材料行经收货计价形成应付,不经费用单';
        END IF;

        -- ── D3 下半:支出的资产必须【就是】行上那一台 ────────────────────────
        -- 拆成三种情形分别点名,因为它们的【修法互不相同】。合成一句"资产对不上"
        -- 会把两种根本不是"对不上"的情形也说成对不上 —— 尤其是新建那一支:
        -- 那里的资产是这一刻才生出来的,报一个"你填的 id 与行上的不符"
        -- 会打发人去核对一个一毫秒之前还不存在的 id。
        IF p_asset IS NULL THEN
            RAISE EXCEPTION 'EXPENSE_NOT_CAPITAL|%|%', v_poline.line_no, p_account_code
              USING HINT = '挂在设备行上的支出必须是资本支出:科目 1500 + p_asset';
        END IF;
        IF (p_asset->>'asset_id') IS NULL THEN
            RAISE EXCEPTION 'EXPENSE_CREATES_ASSET|%', v_poline.line_no
              USING HINT = '设备行引用的资产卡【已经存在】(行不创建资产),这笔支出要以追加模式挂上去:p_asset.asset_id';
        END IF;
        IF (p_asset->>'asset_id')::uuid <> v_poline.asset_id THEN
            RAISE EXCEPTION 'EXPENSE_ASSET_MISMATCH|%|%', p_asset->>'asset_id', v_poline.asset_id
              USING HINT = 'B 机器的发票不能记到 A 机器的订单行上';
        END IF;

        -- ── D2 第四条:供应商一致 —— 但先问【有没有供应商】────────────────────
        -- 【这条规矩的主体可以缺席】expenses_counterparty_shape 只对 unpaid 强制
        -- 往来对象;paid 的费用单 supplier_id 合法地为空(线上那 2 笔就是)。
        -- 于是"供应商一致"若直接写成比较,对一半的单据是拿 NULL 去比 ——
        -- 那不是"不一致",是"没人说过"。两件事两个名字。
        IF p_supplier_id IS NULL THEN
            RAISE EXCEPTION 'EXPENSE_SUPPLIER_NOT_STATED|%', v_poline_po.code
              USING HINT = '挂在采购单行上的支出必须说出开这张票的供应商';
        END IF;
        IF p_supplier_id <> v_poline_po.supplier_id THEN
            RAISE EXCEPTION 'SUPPLIER_MISMATCH|%|%', v_poline_po.code, p_supplier_id;
        END IF;

        -- ── D4:覆盖推导 —— 一条设备行只报销一次 ─────────────────────────────
        -- 【必须排除已冲销的】一笔冲销掉的支出【没有发生过】,它的行因此重新
        -- 可计费。判据只有一句:status = 'posted'。它站得住,是因为
        -- guard_expense_mutation 只放行 posted→reversed 且同时首挂
        -- reversed_by_expense,并且拒绝一切 DELETE —— 两列永远同步,
        -- 所以 status='reversed' 与 reversed_by_expense IS NOT NULL 是同一件事。
        -- 【这段话原本说"冲销了再记一笔"会把成本记成 170,000 —— EQP-1b-iii 之后
        --   它不再成立,所以就地退休,而不是留在这里骗下一个读它的人。】
        -- 当时(EQP-1b-ii)的实测是:冲销一笔追加模式的资本支出【允许】、分录冲掉、
        -- 而 cost_base 与成本明细原样不动,于是"冲销再记"= 100,000 的机器记成 170,000。
        -- EQP-1b-iii 修好了那一条:冲销现在会把成本退回去,并当场核对
        -- 表头 = 未冲销明细之和。所以【未投用】的机器,"冲销那笔支出再记一笔"
        -- 现在是一条安全的路,消息里也就照直说了。
        -- 【但它只在未投用时安全】资产一旦投用,冲销按名拒
        -- (ASSET_IN_SERVICE_COST_LOCKED),而向下修正一台已投用资产的成本
        -- 今天【没有任何路】—— 记在 docs/known-issues.md,带返回条件。
        -- 消息因此仍然把【改订单】放在前面:发票与估价对不上时,那才是要改的东西。
        -- 【第二层是索引】uq_expenses_live_po_line,谓词与这里逐字相同。
        -- 这里负责【可读】(带上占着这条行的那张单的编号),索引负责【正确】
        -- (并发下两笔同时通过本判据时,只有一笔落得下去)—— invoice_lines 的原话。
        SELECT e.code INTO v_billed
        FROM expenses e
        WHERE e.purchase_order_line_id = p_purchase_order_line
          AND e.status = 'posted'
        LIMIT 1;
        IF v_billed IS NOT NULL THEN
            RAISE EXCEPTION 'PO_LINE_ALREADY_EXPENSED|%|%', v_poline.line_no, v_billed
              USING HINT = '一条设备行只报销一次。若是【订单上的估价】与发票对不上,要改的是订单(改行,不是删行),不是再记一笔';
        END IF;
    END IF;

    -- 2. 金额/币种/汇率(FIN-0:SGD 本位免换算,外币按费用日牌价估值)
    IF p_amount IS NULL OR p_amount <= 0 THEN
        RAISE EXCEPTION 'AMOUNT_INVALID';
    END IF;
    IF p_currency IS NULL OR NOT EXISTS (SELECT 1 FROM currencies c WHERE c.code = p_currency) THEN
        RAISE EXCEPTION 'CURRENCY_INVALID|%', COALESCE(p_currency, '?');
    END IF;
    -- FIN-0:本位币 SGD 免换算;外币按【费用日】的行方卖出价(tt_sell)估值 ——
    -- 应付与开销是我们将来要【向银行买】的外币。当日无牌价即拒(FX_RATE_MISSING)。
    -- 汇率不再由调用方递入:牌价属于 fx_rates,不属于表单。
    IF p_fx_rate IS NOT NULL THEN
        RAISE EXCEPTION 'FX_RATE_NOT_ACCEPTED|%', p_currency;
    END IF;
    v_fx := fx_rate_for(p_currency, p_expense_date, 'tt_sell');

    -- 3. 支付状态
    IF p_payment_status IS NULL OR p_payment_status NOT IN ('paid','unpaid') THEN
        RAISE EXCEPTION 'PAYMENT_STATUS_INVALID|%', COALESCE(p_payment_status, '?');
    END IF;
    -- ★★ PAY-REQ-1(Tim 的 Q2(c),2026-09-23):一张费用单【不许生下来就是已付】。
    --   'paid' 这条路直接贷银行、不经 payments、不经 SOD、不经任何批准 ——
    --   是"钱离开之前要先批"那条规矩旁边的一扇侧门。从此费用一律挂账(unpaid),
    --   钱经付款申请 → CFO 批准 → 付款离开。默认值也从 'paid' 改成了 'unpaid'
    --   (一个走默认值就撞拒绝的参数,是 WHT-1 记过的那种坑)。
    --   已批准的流程生成的费用(报销单、医疗申报)本来就传 'unpaid',不受影响;
    --   加工费付款(relieve_processing_accruals)直接写 expenses、不经本函数,也不受影响。
    --   下面 'paid' 那一支因此到不了,留着是为了让这一刀只改一句判断。
    IF p_payment_status = 'paid' THEN
        RAISE EXCEPTION 'EXPENSE_PAID_AT_CREATION_REFUSED'
          USING HINT = '费用先挂账(未付),再提付款申请、经 CFO 批准后付款(PAY-REQ-1)';
    END IF;

    IF p_payment_status = 'paid' THEN
        -- paid:银行科目显式给了必须合法;不给按币种默认 —— 映射只有一份
        -- (bank_account_for_currency,bank_native_currency 的逆)
        IF p_bank_account IS NOT NULL THEN
            IF p_bank_account NOT IN ('1000','1010') THEN
                RAISE EXCEPTION 'BANK_INVALID|%', p_bank_account;
            END IF;
            v_bank := p_bank_account;
        ELSE
            v_bank := bank_account_for_currency(p_currency);
        END IF;
    ELSE
        -- unpaid:必须有在册供应商(它要成为 AP 单据);银行科目必须为空 ——
        -- 传了也直接忽略(挂账时根本没动银行,存下来只会误导)
        -- PAYEE-1a:往来对象【二选一】—— 供应商 或 员工,恰好一个。
        -- 【两个都给是矛盾,不是"取其一"】一笔钱不可能同时欠着两个人;
        -- 悄悄挑一个会让另一个人的账凭空消失,所以按名拒绝。
        IF num_nonnulls(p_supplier_id, p_employee_id) = 0 THEN
            RAISE EXCEPTION 'COUNTERPARTY_REQUIRED_FOR_UNPAID';
        END IF;
        IF num_nonnulls(p_supplier_id, p_employee_id) > 1 THEN
            RAISE EXCEPTION 'COUNTERPARTY_AMBIGUOUS';
        END IF;
        IF p_supplier_id IS NOT NULL
           AND NOT EXISTS (SELECT 1 FROM suppliers WHERE id = p_supplier_id AND deleted_at IS NULL) THEN
            RAISE EXCEPTION 'SUPPLIER_NOT_FOUND|%', p_supplier_id;
        END IF;
        IF p_employee_id IS NOT NULL
           AND NOT EXISTS (SELECT 1 FROM employees WHERE id = p_employee_id AND deleted_at IS NULL) THEN
            RAISE EXCEPTION 'EMPLOYEE_NOT_FOUND|%', p_employee_id;
        END IF;
        v_bank := NULL;
    END IF;

    -- 4. 净额。**amount_ccy 始终是【不含税净额】** —— 供应商账单上的总额
    --    是净额 + 税,而这一列记的是开支本身的价值。GST 关着时两者相等,
    --    所以这条口径对既有行为是恒等的。
    --    CLAIM-GST-1(Tim Q3):p_amount 的含义由 p_amount_includes_tax 说出来。
    --      · false(默认,费用表单、供应商账单):p_amount 就是净额,税在上面另算;
    --      · true(只有报销单与医疗申报两条路传):p_amount 是【收据上的总额】,
    --        税从里面拆出来(tax_included_in),净额 = 总额 − 税。
    --    净额要等税率解析出来才知道,所以本位币净额挪到 4b 之后算。
    v_net := p_amount;

    -- ════════════════════════════════════════════════════════════════════════
    -- 4b. GST-2:进项税码 —— 【供应商默认 + 本单改写】,税率按【费用日】解析。
    -- 【为什么费用日就是税点】进项侧的税点是供应商那张税务发票的日期,
    -- 而 record_expense 的 p_expense_date 记的正是那一天。总账口径与法定口径
    -- 在进项侧本来就重合 —— 所以 F5 的进项侧仍然从总账推导,那不是妥协。
    -- ════════════════════════════════════════════════════════════════════════
    IF gst_registered() THEN
        SELECT default_tax_code INTO v_sup_default FROM suppliers WHERE id = p_supplier_id;
        -- 【没有供应商的 paid 单据必须自己带码】那是合法的一种单据
        -- (线上就有两笔),而它没有可以继承默认的对象 —— 于是要么本单指定,
        -- 要么按名拒。不猜。
        v_tax_code := resolve_tax_code(p_tax_code, v_sup_default, 'input', 'supplier');
        v_tax_rate := tax_rate_for(v_tax_code, p_expense_date);
        -- PO-GST-1:提取成 tax_amount_for —— 【表达式一个字符都没变】,
        -- 只是这一行此前在三处各写了一遍。见该函数抬头。
        -- CLAIM-GST-1:含税总额 → 先定税(IRAS 税分数)、净额取差,于是 净 + 税 恒等于 总额;
        -- 不含税净额 → 税在上面另算,与此前逐字相同。
        IF p_amount_includes_tax THEN
            v_tax_ccy := tax_included_in(p_amount, v_tax_rate);
            v_net     := p_amount - v_tax_ccy;
        ELSE
            v_tax_ccy := tax_amount_for(p_amount, v_tax_rate);
        END IF;
        v_tax_base := round(v_tax_ccy * v_fx, 2);
        SELECT is_claimable INTO v_claimable FROM tax_codes WHERE code = v_tax_code;
    ELSE
        -- 【未注册:与建 GST 之前一模一样】传了码要按名拒,不能悄悄忽略。
        IF NULLIF(btrim(COALESCE(p_tax_code, '')), '') IS NOT NULL THEN
            RAISE EXCEPTION 'GST_NOT_REGISTERED|%', p_tax_code;
        END IF;
    END IF;
    v_amount_base := round(v_net * v_fx, 2);

    -- ════════════════════════════════════════════════════════════════════════
    -- 4c. WHT-1:预提税 —— **这张单要不要替收款人代扣,以及扣多少**。
    --
    -- ★【这【不是】GST 的第二个实例,两者在这张单上做的是相反的事】★
    --   进项税是【加】在供应商账单上、公司还能要回来的钱;
    --   预提税是【从】要付给供应商的钱里【扣下来】、替他交给 IRAS 的钱。
    --   所以这一段不碰分录:记这张费用单的时候什么都没扣 —— 债是全额的。
    --   代扣发生在【付款】那一刻(record_payment),因为法定义务是就
    --   "你实际付出去的那部分"代扣。这里只把【裁定】冻下来。
    --
    -- 【裁定的三个部件,以及它们各自的来路】
    --   ① 居民身份 —— 从 suppliers.tax_residence 抄一份冻住(见列注释);
    --   ② 性质     —— 由记账人显式回答,'none' 是一个合法且显式的"否";
    --   ③ 税率     —— wht_rate_for(性质, 费用日),条约减免时由本单覆盖并出示凭据。
    -- ════════════════════════════════════════════════════════════════════════
    v_residence  := NULL;
    v_wht_nature := NULLIF(btrim(COALESCE(p_wht_nature, '')), '');
    v_wht_ref    := NULLIF(btrim(COALESCE(p_wht_treaty_ref, '')), '');
    IF p_supplier_id IS NOT NULL THEN
        SELECT tax_residence INTO v_residence FROM suppliers WHERE id = p_supplier_id;
    END IF;

    IF v_wht_nature IS NOT NULL THEN
        -- ── 有人断言这张单要做代扣裁定 ──────────────────────────────────
        -- 【收款人必须是供应商】员工与"只有名字的收款人"都到不了这里:
        -- employees 没有税务居民身份这一列,而 payee_name 是一段自由文本 ——
        -- 对一段文本做税务裁定是没有主语的。两者都是【具名缺席】,记在
        -- docs/known-issues.md,不是靠这里悄悄放过。
        IF p_supplier_id IS NULL THEN
            RAISE EXCEPTION 'WHT_PAYEE_NOT_A_SUPPLIER|%', v_wht_nature
              USING HINT = '预提税裁定只能落在一个在册供应商上 —— 员工报销与只有名字的收款人不在本刀范围内';
        END IF;
        IF v_residence IS NULL THEN
            RAISE EXCEPTION 'WHT_RESIDENCE_NOT_STATED|%', p_supplier_id
              USING HINT = '这家供应商还没有申报税务居民身份 —— 先在供应商档案上填,再记这张单';
        END IF;
        IF v_residence <> 'non_resident' THEN
            -- 居民收款人不代扣。悄悄扣 0 会在账上留下一条"想过了"的假痕迹。
            RAISE EXCEPTION 'WHT_PAYEE_IS_RESIDENT|%|%', p_supplier_id, v_wht_nature
              USING HINT = '这家供应商申报的是新加坡税务居民 —— 付给他的款不代扣';
        END IF;
        -- ★【A2:'paid' 那一支按名拒,并且【说出该怎么走】】★
        --   record_expense 的 p_payment_status 默认就是 'paid',而那一支
        --   借 6xxx / 贷银行 一步到位,不产生应付、不经过 record_payment ——
        --   也就是不经过唯一知道怎么劈账的那段代码。让它自己也会劈,
        --   就是把同一份算术写第二遍(AGENTS.md 的预览规则,已犯四次)。
        --   【一条不指路的拒绝,在默认路径上就是一条会被绕开的拒绝】——
        --   所以 HINT 说的是走法,不是"不行"。
        --   ★【判据是【真的要扣钱吗】,不是【回答了这个问题吗】★
        --   fu2 修正:原实现把这道拒绝放在解析税率【之前】,谓词只看
        --   "有没有给性质"。于是对一个非居民收款人当场付清一笔【不适用代扣】的
        --   款(性质 = 'none',税率 0),它也拒 —— 而那一支非居民收款人的
        --   paid 费用单因此【一条路都没有】:不回答被 WHT_NATURE_REQUIRED 拒,
        --   回答"不适用"被这一条拒。**一个两边都堵死的问题,不是一道闸,是一堵墙。**
        --   所以税率先解析,再按【税率 > 0】判 —— 没有钱要被扣下来的时候,
        --   paid 那一支没有任何东西需要劈,也就没有理由拦它。
        --   (界面那一侧本来就写对了:`whtNature !== 'none' && paid` 才提示。
        --    两边不一致时先问哪一边错了 —— 这一次错的是服务端。)
        v_wht_statutory := wht_rate_for(v_wht_nature, p_expense_date);
        IF p_wht_rate_pct IS NULL THEN
            -- 没有主张条约减免:按法定税率。
            IF v_wht_ref IS NOT NULL THEN
                RAISE EXCEPTION 'WHT_TREATY_REF_WITHOUT_RATE|%', v_wht_ref
                  USING HINT = '给了居民证明书编号却没有给协定税率 —— 两者要么都给,要么都不给';
            END IF;
            v_wht_rate := v_wht_statutory;
        ELSE
            IF p_wht_rate_pct < 0 THEN
                RAISE EXCEPTION 'WHT_TREATY_RATE_INVALID|%', p_wht_rate_pct;
            END IF;
            -- 【永远不许高于法定】协定只会调低,不会调高。高于法定的"减免"
            -- 是一个打错的数字,而它会算得出来。
            IF p_wht_rate_pct > v_wht_statutory THEN
                RAISE EXCEPTION 'WHT_TREATY_RATE_ABOVE_STATUTORY|%|%|%',
                    v_wht_nature, p_wht_rate_pct, v_wht_statutory;
            END IF;
            -- 【低于法定必须出示凭据】没有居民证明书,IRAS 按法定税率征,
            -- 协定写什么都不作数 —— 所以少扣的那一部分是公司自己要补的钱。
            IF p_wht_rate_pct < v_wht_statutory AND v_wht_ref IS NULL THEN
                RAISE EXCEPTION 'WHT_TREATY_REF_REQUIRED|%|%|%',
                    v_wht_nature, p_wht_rate_pct, v_wht_statutory
                  USING HINT = '低于法定税率要凭居民证明书(Certificate of Residence)—— 填它的编号';
            END IF;
            v_wht_rate := p_wht_rate_pct;
        END IF;
        -- ★【A2:'paid' 那一支按名拒,并且【说出该怎么走】】★
        --   record_expense 的 p_payment_status 默认就是 'paid',而那一支
        --   借 6xxx / 贷银行 一步到位,不产生应付、不经过 record_payment ——
        --   也就是不经过唯一知道怎么劈账的那段代码。让它自己也会劈,
        --   就是把同一份算术写第二遍(AGENTS.md 的预览规则,已犯四次)。
        --   【一条不指路的拒绝,在默认路径上就是一条会被绕开的拒绝】——
        --   所以 HINT 说的是走法,不是"不行"。
        --   【谓词是税率 > 0】见上面 fu2 那段:不扣钱就没有要劈的东西。
        IF p_payment_status = 'paid' AND v_wht_rate > 0 THEN
            RAISE EXCEPTION 'WHT_ON_PAID_EXPENSE_UNSUPPORTED|%', v_wht_nature
              USING HINT = '要代扣的费用请先记成【未付】(挂应付),再用付款功能付掉 —— 代扣在付款那一步发生,那里只有一份劈账的实现';
        END IF;

        -- 【预期值:全额结清时会扣多少】真正的代扣按实付部分算,见 record_payment。
        v_wht_ccy := round(v_net * v_wht_rate / 100.0, 2);
    ELSE
        -- ── 没有给性质 ──────────────────────────────────────────────────
        IF p_wht_rate_pct IS NOT NULL OR v_wht_ref IS NOT NULL THEN
            RAISE EXCEPTION 'WHT_NATURE_REQUIRED|rate_without_nature'
              USING HINT = '给了协定税率或证明书编号,却没有说这笔款是什么性质';
        END IF;
        -- ★【承重的那一条】★ 收款人【申报过】是非居民,就必须回答这个问题。
        --   答"不适用"用 'none' —— 它是一个显式的否,不是一个空白。
        --   身份为 NULL 时【不问】:那是一个量过成本的取舍,理由整段写在
        --   db/tables/suppliers.sql 的 tax_residence 列注释里,不在这里复述。
        IF v_residence = 'non_resident' THEN
            RAISE EXCEPTION 'WHT_NATURE_REQUIRED|%', p_supplier_id
              USING HINT = '收款人是非居民 —— 说明这笔款的预提税性质;确实不适用就选「不适用代扣」(none),不要留空';
        END IF;
    END IF;

    -- ════════════════════════════════════════════════════════════════════════
    -- AP-RECON-1(Tim AP-RECON-1 Q2):【同一张单既要代扣又带进项税 —— 按名拒】
    --   应付额现在是 净额 + 税(amount_ccy + tax_ccy),而代扣按【实付的核销额】× 税率算
    --   (record_payment)。两者同在一张单上,代扣就会把 GST 也扣进去,Σ 代扣超过这里冻下的
    --   wht_amount_ccy(fixture 142 D 臂钉的那个等式)。
    --   而这个组合在现实里本不该出现:要代扣的是【非居民】收款人,非居民供应商不收新加坡 GST
    --   (进口服务走反向征收,不是账单上的税)。线上 0 张这样的单。所以拒绝不挡任何真业务,
    --   只挡一个会让两条规矩算出互相矛盾的数的输入。判据与 A2 同形:【真的要扣钱】且【真的有税】。
    -- ════════════════════════════════════════════════════════════════════════
    IF COALESCE(v_wht_rate, 0) > 0 AND COALESCE(v_tax_ccy, 0) > 0 THEN
        RAISE EXCEPTION 'EXPENSE_WHT_WITH_GST|%|%', v_wht_nature, v_tax_code
          USING HINT = '要代扣预提税的非居民收款人不应在账单上收新加坡 GST —— 请核对税码(非居民服务通常不带进项税码)';
    END IF;

    -- 【资本化口径:不可抵的进项税【是】资产成本的一部分】
    -- 可抵的税要得回来,它从来不是成本;不可抵的税(BL —— 私家车是最典型的
    -- 那一类)要不回来,于是它和买价一样是为了取得这台资产付出去的钱。
    -- 【为什么不在这里按名拒掉 BL + 资本】那会把一个【有确定答案的】会计问题
    -- 说成一个待裁决的问题。ASSET_ALREADY_IN_SERVICE 那条拒绝之所以成立,
    -- 是因为"投用后的追加是资本化改良还是当期费用"真的需要人来判;这一条不需要。
    v_cost_ccy  := round(v_net       + CASE WHEN v_claimable THEN 0 ELSE v_tax_ccy  END, 2);
    v_cost_base := round(v_amount_base + CASE WHEN v_claimable THEN 0 ELSE v_tax_base END, 2);

    -- 5. 无缝编号:咨询锁串行化"取当年最大号+1"(同 JE/收付款编号手法);失败回滚会释放号码。
    v_year := EXTRACT(YEAR FROM p_expense_date)::integer;
    PERFORM pg_advisory_xact_lock(hashtext('expense_code_' || v_year::text)::bigint);
    SELECT COALESCE(MAX(split_part(code, '-', 3)::integer), 0) + 1
    INTO v_seq
    FROM expenses
    WHERE code LIKE document_type_prefix('expense') || '-' || v_year::text || '-%';
    v_code := document_type_prefix('expense') || '-' || v_year::text || '-' || LPAD(v_seq::text, 4, '0');

    -- 6. 先过分录(source_id = 预生成的 expense id,无需回填),期间锁在此生效。
    --    paid → 贷银行;unpaid → 贷 2000 应付。行走原币。
    -- ── GST-2:分录的形状 ────────────────────────────────────────────────
    -- 【净额那条腿带税码】F5 的 box5 = Σ(借−贷) FILTER (tax_code IN (TX,ZP,BL)),
    -- 所以它报的是【采购净额】,这正是 IRAS 要的"应税采购总额"。
    v_jlines := jsonb_build_array(
        jsonb_build_object('account_code', p_account_code, 'side', 'debit',
                           'currency', p_currency, 'amount_ccy', v_net, 'fx_rate', v_fx,
                           'tax_code', v_tax_code));
    IF v_tax_ccy > 0 THEN
        IF v_claimable THEN
            -- 可抵:税借 1400 进项税 —— box7 就是从这个科目推导的。
            v_jlines := v_jlines || jsonb_build_object('account_code', '1400', 'side', 'debit',
                'currency', p_currency, 'amount_ccy', v_tax_ccy, 'fx_rate', v_fx,
                'line_memo', 'input tax ' || v_tax_code);
        ELSE
            -- 【不可抵(BL)不是"没有税",是"有税但要不回来"】那笔税进【开支本身】。
            -- 【这条腿【不带】税码】带上它,box5 报的就成了含税额,而 IRAS 要的是
            -- 采购价值 —— 税码存在的全部理由正是"税率分不开可抵与不可抵"。
            v_jlines := v_jlines || jsonb_build_object('account_code', p_account_code, 'side', 'debit',
                'currency', p_currency, 'amount_ccy', v_tax_ccy, 'fx_rate', v_fx,
                'line_memo', 'blocked input tax ' || v_tax_code);
        END IF;
    END IF;
    -- 【贷方拆成两条腿,而不是一条总额腿】供应商收的是净额 + 税,但
    -- post_journal_entry 是【逐行】round(原币 × 汇率) 的:一条 round((净+税)×fx)
    -- 的腿与两条 round(净×fx) + round(税×fx) 的借方腿会差一分钱,而那一分钱
    -- 会撞上提交时的借贷平衡触发器。两条腿按构造精确对冲,不靠运气。
    v_jlines := v_jlines || jsonb_build_object(
        'account_code', CASE WHEN p_payment_status = 'paid' THEN v_bank ELSE '2000' END,
        'side', 'credit',
        'currency', p_currency, 'amount_ccy', v_net, 'fx_rate', v_fx);
    IF v_tax_ccy > 0 THEN
        v_jlines := v_jlines || jsonb_build_object(
            'account_code', CASE WHEN p_payment_status = 'paid' THEN v_bank ELSE '2000' END,
            'side', 'credit',
            'currency', p_currency, 'amount_ccy', v_tax_ccy, 'fx_rate', v_fx,
            'line_memo', 'GST on ' || v_code);
    END IF;

    v_je := post_journal_entry(
        p_expense_date,
        'Expense ' || v_code || ' ' || p_account_code,
        'expense', v_expense_id,
        v_jlines
    );

    -- 7. 插入开支单(带着分录链接一次到位;不可变表无后续 UPDATE)
    INSERT INTO expenses (id, code, expense_date, account_code, amount_ccy, currency, fx_rate,
                          amount_base, payment_status, bank_account_code, supplier_id, employee_id,
                          payee_name, notes, journal_entry_id, created_by,
                          purchase_order_line_id,
                          tax_code, tax_rate_pct, tax_base, tax_ccy,
                          -- WHT-1:裁定冻在债务上。居民身份是【抄下来的一份】,
                          -- 不是一个指向 suppliers 的引用 —— 供应商日后迁走管理与
                          -- 控制、身份跟着变,不能倒过来改写一张已经记下的债务。
                          wht_payee_residence, wht_nature, wht_rate_pct,
                          wht_amount_ccy, wht_treaty_ref)
    VALUES (v_expense_id, v_code, p_expense_date, p_account_code, v_net, p_currency, v_fx,
            v_amount_base, p_payment_status, v_bank, p_supplier_id, p_employee_id,
            p_payee_name, p_notes, (v_je->>'entry_id')::uuid, v_user,
            p_purchase_order_line,
            v_tax_code,
            CASE WHEN v_tax_code IS NULL THEN NULL ELSE v_tax_rate END,
            v_tax_base, v_tax_ccy,
            -- 【只有做过裁定的单据才带身份】没有裁定时这四列全空,与
            -- expenses_wht_shape 那条 CHECK 的第一支逐字对应。居民收款人、
            -- 员工报销、身份未申报 —— 三种情况在这里都是空,而它们的
            -- 【区别】记在别处(拒绝的名字、以及 /finance/wht 数出来的缺口)。
            CASE WHEN v_wht_nature IS NULL THEN NULL ELSE v_residence END,
            v_wht_nature,
            CASE WHEN v_wht_nature IS NULL THEN NULL ELSE v_wht_rate END,
            CASE WHEN v_wht_nature IS NULL THEN 0    ELSE v_wht_ccy END,
            CASE WHEN v_wht_nature IS NULL THEN NULL ELSE v_wht_ref END);

    -- FIN-22:资本行 → 同一事务生成台账。成本 = 本单金额;汇率 = 上面按
    -- 【费用日 = 购置日】取的 tt_sell 牌价 —— 资产是非货币项目,这个汇率
    -- 定格成本,永不重译(表注有言,重估扫不到 1500/1510)。
    IF p_asset IS NOT NULL THEN
        -- ── FA-1a:同一扇门,两种模式 ────────────────────────────────────────
        -- 【为什么不开第二个函数】1500 ↔ p_asset 的互相要求是这条路上唯一的
        -- 不变量:没有台账行的 1500 借方进不来,资本标记也落不到别的科目上。
        -- 再开一个 add_cost_to_asset() 等于开第二扇门,而那个不变量只守得住
        -- 第一扇 —— 与"单据不该有第二个写法"同一条(so_issues / approval_log)。
        -- 所以追加走【同一个函数】:p_asset 带 asset_id 就是追加,不带就是新建。
        v_append_id := (p_asset->>'asset_id')::uuid;

        IF v_append_id IS NOT NULL THEN
            -- ── 追加成本(运费、关税、安装调试)──────────────────────────
            SELECT * INTO v_target FROM fixed_assets WHERE id = v_append_id FOR UPDATE;
            IF NOT FOUND THEN
                RAISE EXCEPTION 'ASSET_NOT_FOUND|%', v_append_id;
            END IF;
            IF v_target.status <> 'active' THEN
                RAISE EXCEPTION 'ASSET_DISPOSED|%', v_target.code;
            END IF;

            -- ════════════════════════════════════════════════════════════════
            -- ★★【CAPEX-1:投用之后的追加 —— 那条【一律拒】换成了一条【窄】的】★★
            --
            -- FIN-22 原本在这里无条件拒(ASSET_ALREADY_IN_SERVICE),而它守的是
            -- **两件事**,必须分开说,因为只有一件被解决了:
            --   ① 【算术危险】抬高 cost_base 会让累计目标算法把过去每一个月
            --      重算一遍,整笔补提落在本期。
            --      —— 这一件由 fixed_asset_depreciation_anchors 【结构性】解决了:
            --      锚点之前那一段成了一个存下来的常数,新成本乘不到它身上。
            --   ② 【会计判断】投用后的花费算资本化改良,还是算当期费用?
            --      —— 这一件【没有】被解决,也解决不了:它是人的判断。
            --
            -- 所以窄的那条规矩保住的正是②:**判断仍然交还给人,只是人现在可以
            -- 在系统里回答,而不是被挡在门外。** 而回答的地方【不新开一处】——
            -- equipment_maintenance 已经是记录这个判断的地方(capitalised +
            -- capitalisation_reason,表上有 CHECK 逼理由非空),而
            -- capitalised_expense_id 这一列的注释早就写着它在等的就是这一刀。
            --
            -- 【为什么不接受一段自由文本的理由参数】那会让"这笔钱是资本化的、
            -- 理由是什么"同时住在两张表里,而两处之间没有任何链接 ——
            -- 一个判断两个真源。Tim 2026-08-29 裁定:走维修记录这一条路。
            --
            -- 【那条被关掉的路,按名拒并说出走法】一次不经维修记录的中途升级
            -- (比如按采购而不是按维修记下来的)今天没有路。**不给它开第二个
            -- 入口**:两个来源加一条优先级规则,是第二个定义披着"打平局"的外衣。
            -- 拒绝要指路 —— 先记一条维修记录、标资本化并写明理由,再对着它资本化。
            IF v_target.in_service_date IS NOT NULL THEN
                IF p_maintenance_id IS NULL THEN
                    RAISE EXCEPTION 'ASSET_IN_SERVICE_NEEDS_MAINTENANCE|%|%',
                        v_target.code, v_target.in_service_date
                      USING HINT = '给一台在跑的机器追加成本,要先有一条【标了资本化并写明理由】的维修记录,再对着它资本化 —— 那个判断(资本化改良 vs 当期费用)是人的,系统不替你做';
                END IF;
                SELECT * INTO v_maint FROM equipment_maintenance
                 WHERE id = p_maintenance_id FOR UPDATE;
                IF NOT FOUND THEN
                    RAISE EXCEPTION 'MAINTENANCE_NOT_FOUND|%', p_maintenance_id;
                END IF;
                -- 【维修记录必须指着【这一台】】否则一次资本化会挂到别的机器的判断上。
                IF v_maint.equipment_id IS DISTINCT FROM v_append_id THEN
                    RAISE EXCEPTION 'MAINTENANCE_ASSET_MISMATCH|%|%', v_target.code, p_maintenance_id;
                END IF;
                -- 【判断必须已经做过】capitalised = false 意味着没有人说过这是资本化。
                -- 表上那条 CHECK 保证 capitalised ⇒ 理由非空,所以到这里理由必然有。
                IF NOT v_maint.capitalised THEN
                    RAISE EXCEPTION 'MAINTENANCE_NOT_CAPITALISED|%', p_maintenance_id
                      USING HINT = '这条维修记录没有被标成资本化 —— 先在机器页上把它标成资本化并写明理由';
                END IF;
                -- 【一条维修记录只资本化一次】否则同一次大修会被加两遍成本。
                IF v_maint.capitalised_expense_id IS NOT NULL THEN
                    RAISE EXCEPTION 'MAINTENANCE_ALREADY_CAPITALISED|%|%',
                        p_maintenance_id, v_maint.capitalised_expense_id;
                END IF;
            ELSIF p_maintenance_id IS NOT NULL THEN
                -- 还没投用的机器不需要这条路 —— 成本本来就加得上去。
                -- 悄悄忽略这个参数会让调用方以为它起了作用。
                RAISE EXCEPTION 'MAINTENANCE_NOT_APPLICABLE|%', v_target.code
                  USING HINT = '这台机器还没投用,成本直接加得上去,不需要经维修记录';
            END IF;

            -- 每一笔追加带【自己的】三件套:原币金额、它自己那天的汇率、本位币额。
            -- 表头那三列是【第一笔】的(购置那一笔),不是合计 —— 合计只有
            -- cost_base 一个数,而各笔的原币可以不同(进口机器 USD、本地运费 SGD)。
            INSERT INTO fixed_asset_cost_entries
                (asset_id, expense_id, amount_ccy, currency, fx_rate, amount_base, created_by)
            VALUES (v_append_id, v_expense_id, v_cost_ccy, p_currency, v_fx, v_cost_base, v_user);

            UPDATE fixed_assets
               SET cost_base = cost_base + v_cost_base
             WHERE id = v_append_id;

            -- ════════════════════════════════════════════════════════════════
            -- ★★【CAPEX-1:落一个折旧锚点 —— 这里就是回溯补提被挡住的地方】★★
            --
            -- 上面那句 UPDATE 刚把 cost_base 抬高了。**如果什么都不做**,
            -- 月度例程下一次跑就会用新成本把【每一个已经过去的月份】的目标重算,
            -- 整笔补提落在本期 —— 那正是 4.7 明令禁止的。
            --
            -- 锚点把"过去那一段"冻成一个数:
            --   · pre_anchor_target_base = 按【锚点之前】那套算术、到锚点前一天
            --     为止【应当】累计多少。**注意是"应当",不是"已经提了多少"** ——
            --     欠着的那几期仍要按【旧费率】补上(delta = target − 已提 自动做到),
            --     不该被卷进新费率里摊掉。
            --   · remaining_months = 现行那一段的剩余月数,减去它已经走掉的部分。
            --     递归地写:没有现行锚点时,现行那一段就是"从投用日起、共 useful_life
            --     个月",于是这条式子对首次与第二次资本化是同一条。
            --
            -- 【生效日取当月 1 号】资本化落在哪个月,就从那个月末那一次起用新费率。
            IF v_target.in_service_date IS NOT NULL THEN
                v_anchor_from := date_trunc('month', p_expense_date)::date;

                SELECT * INTO v_prev FROM fixed_asset_depreciation_anchors an
                 WHERE an.asset_id = v_append_id AND an.effective_from <= v_anchor_from
                 ORDER BY an.effective_from DESC LIMIT 1;
                IF FOUND THEN
                    v_prev_start := v_prev.effective_from;
                    v_prev_rem   := v_prev.remaining_months;
                    -- 锚点之前那一段的目标 = 上一个常数 + 上一段走掉的部分
                    v_pre_target := v_prev.pre_anchor_target_base
                        + LEAST(round(v_target.cost_base - v_cost_base - v_target.residual_base
                                      - v_prev.pre_anchor_target_base, 2),
                                round((v_target.cost_base - v_cost_base - v_target.residual_base
                                       - v_prev.pre_anchor_target_base)
                                      / v_prev.remaining_months
                                      * depreciation_months_elapsed(v_prev_start, v_anchor_from - 1), 2));
                ELSE
                    v_prev_start := v_target.in_service_date;
                    v_prev_rem   := v_target.useful_life_months;
                    -- 【注意 cost_base 减回本次追加】v_target 是 UPDATE 之【前】读的那一行,
                    -- 所以它的 cost_base 本来就是旧值 —— 这里不减。写出来是因为
                    -- 下一个读的人会问:常数用的是【加钱之前】的成本吗?是。
                    v_pre_target := LEAST(
                        round(v_target.cost_base - v_target.residual_base, 2),
                        round((v_target.cost_base - v_target.residual_base)
                              / v_target.useful_life_months
                              * depreciation_months_elapsed(v_prev_start, v_anchor_from - 1), 2));
                END IF;

                v_rem := round(v_prev_rem
                               - depreciation_months_elapsed(v_prev_start, v_anchor_from - 1), 6);
                -- 【寿命走完的机器不许再资本化】剩余月数 ≤ 0 时那条公式的分母是零或负,
                -- 而它背后的现实是:一台已经提完的机器,再投的钱要么是当期费用,
                -- 要么需要先重估寿命 —— 两者都不是这条路。按名拒,不猜。
                IF v_rem <= 0 THEN
                    RAISE EXCEPTION 'ASSET_LIFE_EXHAUSTED|%|%', v_target.code, v_target.useful_life_months
                      USING HINT = '这台机器的使用年限已经走完,没有"剩余年限"可以摊 —— 这笔钱要么是当期费用,要么先要有一次使用年限重估(那一条还没有建,见 docs/known-issues.md)';
                END IF;

                INSERT INTO fixed_asset_depreciation_anchors
                    (asset_id, effective_from, pre_anchor_target_base, remaining_months,
                     expense_id, maintenance_id, reason, created_by)
                VALUES (v_append_id, v_anchor_from, v_pre_target, v_rem,
                        v_expense_id, p_maintenance_id, v_maint.capitalisation_reason, v_user);

                -- 【回填 capitalised_expense_id —— 1.5 找到的那个缺口在这里闭合】
                -- 在此之前没有任何一条代码路径写过这一列,因为这笔支出建不出来。
                UPDATE equipment_maintenance
                   SET capitalised_expense_id = v_expense_id
                 WHERE id = p_maintenance_id;
            END IF;

            RETURN jsonb_build_object(
                'expense_id', v_expense_id,
                'asset_id', v_append_id, 'asset_code', v_target.code,
                'asset_mode', 'append',
                -- CAPEX-1:把锚点回给调用方 —— 屏幕要说得出"从这个月起按新费率摊,
                -- 还剩几个月",而不是让页面自己再算一遍。
                'anchor_from', v_anchor_from,
                'anchor_remaining_months', v_rem,
                'journal_entry_id', (v_je->>'entry_id')::uuid,
                'journal_code', v_je->>'code',
                'code', v_code);
        END IF;

        -- ── 新建(FIN-22 起的原样路径)──────────────────────────────────────
        -- 【两扇建卡的门,而【两扇都不是遗留】—— EQP-1c-a 记在这里,免得下一个
        --   读到 create_fixed_asset 的人以为这一支该被删掉。】
        --   * 这一支(卡与成本【同时】诞生):一台【没有采购单、当场买断】的机器。
        --     那件事的真实形状就是"一张发票同时带来这台机器和它的成本",
        --     硬要拆成两步反而是编造一个不存在的中间状态。
        --   * create_fixed_asset(卡先诞生、成本后到):设备采购的常态 ——
        --     先下单(而采购单行必须引用一张【已存在】的卡,EQP-1a),
        --     后开票。发票经【追加】模式落到那张卡上。
        --   判据一句话:**这台机器在拿到它的成本之前,需不需要先被别的单据引用?**
        --   需要 → create_fixed_asset;不需要 → 这一支。
        IF COALESCE(p_asset->>'description', '') = '' THEN
            RAISE EXCEPTION 'ASSET_DESCRIPTION_REQUIRED';
        END IF;
        v_life := (p_asset->>'useful_life_months')::integer;
        IF v_life IS NULL OR v_life <= 0 THEN
            RAISE EXCEPTION 'ASSET_LIFE_INVALID|%', COALESCE(p_asset->>'useful_life_months', '?');
        END IF;
        v_residual := COALESCE((p_asset->>'residual_base')::numeric, 0);
        IF v_residual < 0 OR v_residual >= v_cost_base THEN
            RAISE EXCEPTION 'ASSET_RESIDUAL_INVALID|%|%', v_residual, v_cost_base;
        END IF;
        v_in_service := (p_asset->>'in_service_date')::date;
        IF v_in_service IS NOT NULL AND v_in_service < p_expense_date THEN
            RAISE EXCEPTION 'ASSET_IN_SERVICE_BEFORE_ACQUISITION|%|%', v_in_service, p_expense_date;
        END IF;

        v_asset_id := gen_random_uuid();
        -- EQP-1c-a:取号提成 next_fixed_asset_code(),两扇门共用一个号段。
        -- 【行为逐字不变】它就是原来这四行:同一把咨询锁(键也是按年拼的
        -- 'fixed_asset_code_'||year)、同一个"当年最大号 + 1"。提出来是因为
        -- 现在有【两扇】建卡的门,而两份同样的取号逻辑迟早会漂开。
        v_asset_code := next_fixed_asset_code(p_expense_date);

        INSERT INTO fixed_assets (id, code, description, category, acquisition_date, in_service_date,
                                  cost_ccy, currency, fx_rate, cost_base, useful_life_months,
                                  residual_base, depreciation_account_code, expense_id, notes, created_by)
        VALUES (v_asset_id, v_asset_code, p_asset->>'description',
                COALESCE(p_asset->>'category', 'equipment'),
                p_expense_date, v_in_service,
                v_cost_ccy, p_currency, v_fx, v_cost_base, v_life,
                v_residual, COALESCE(p_asset->>'depreciation_account_code', '6700'),
                v_expense_id, p_asset->>'notes', v_user);

        -- 【第一笔也进明细表】否则"这台机器的成本由哪几笔构成"对第一笔要查
        -- expenses、对后续几笔要查明细表 —— 两处读法,迟早各说各话。
        INSERT INTO fixed_asset_cost_entries
            (asset_id, expense_id, amount_ccy, currency, fx_rate, amount_base, created_by)
        VALUES (v_asset_id, v_expense_id, v_cost_ccy, p_currency, v_fx, v_cost_base, v_user);
    END IF;

    RETURN jsonb_build_object(
        'expense_id', v_expense_id,
        'asset_id', v_asset_id, 'asset_code', v_asset_code,
        'code', v_code,
        'amount_base', v_amount_base,
        -- CLAIM-GST-1:净额与税分开回给调用方(含税总额进来时,屏幕要说得出拆成了什么)
        'amount_ccy', v_net, 'tax_ccy', v_tax_ccy,
        'journal_code', v_je->>'code',
        'payment_status', p_payment_status,
        -- WHT-1:把裁定回给调用方,让屏幕说得出"这张单付的时候会扣多少" ——
        -- 而不是让页面自己再乘一遍(那就是第二份实现)。
        'wht_nature', v_wht_nature,
        'wht_rate_pct', CASE WHEN v_wht_nature IS NULL THEN NULL ELSE v_wht_rate END,
        'wht_amount_ccy', CASE WHEN v_wht_nature IS NULL THEN 0 ELSE v_wht_ccy END,
        'currency', p_currency
    );
END;
$function$
;

-- ═══ db/functions/decide_expense_claim.sql ═══
CREATE OR REPLACE FUNCTION public.decide_expense_claim(p_claim_id uuid, p_approve boolean, p_account_code text DEFAULT NULL::text, p_tax_code text DEFAULT NULL::text, p_posting_date date DEFAULT NULL::date, p_notes text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_c        expense_claims%ROWTYPE;
    v_emp      employees%ROWTYPE;
    v_has_att  boolean;
    v_exp      jsonb;
    v_date     date;
    v_base     numeric;
    v_level    smallint;
    v_appr_on  boolean := approvals_enabled();
BEGIN
    -- ① APR-3(Q1):门是【看得见财务 + 看得见金额】,不是【改得了财务】。
    --    两个码分两句,与 approve_purchase_order 同形 —— 拒绝要说清缺的是哪一个。
    PERFORM require_permission('module.finance.view');
    PERFORM require_permission('data.view_prices');

    SELECT * INTO v_c FROM expense_claims WHERE id = p_claim_id FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'EXPENSE_CLAIM_NOT_FOUND|%', COALESCE(p_claim_id::text, '?');
    END IF;
    IF v_c.status <> 'submitted' THEN
        RAISE EXCEPTION 'EXPENSE_CLAIM_NOT_SUBMITTED|%|%', v_c.code, v_c.status;
    END IF;
    SELECT * INTO v_emp FROM employees WHERE id = v_c.employee_id;

    -- ══ ★② 四眼:全库【唯一】一份判据,两条腿 ★ ════════════════════════════
    -- 【为什么这道闸必须在这里】SOD-1 的 guard_payment_sod 明确豁免了付给员工的
    -- 款,理由是"由 HR 建档、财务付款,已经跨了两个模块的门"。那句话在写下的
    -- 那天是对的 —— 而 CLAIM-1 开出了一条新路:**员工自己发起**。发起人现在
    -- 就是受益人,那个论证对新路不成立。「换了推导来源,闸就要跟着搬」。
    -- 【两条腿各是谁】raiser = 提这张单的人(代人录入时不是员工本人);
    -- subject = 这张单【说的是谁】,也就是拿到这笔钱的那位员工。
    -- 顺序是定的:raiser 先判(APR-2 §3.5)。
    PERFORM forbid_self_approval(v_c.created_by, v_c.employee_id, 'expense_claim');

    -- ══ ★③ 分档 ★ ════════════════════════════════════════════════════════
    -- 【只在审批开着时问这一句】关着的时候,分档是一个没有意义的动作:
    -- 没有哪一级在生效,而 require_approver_for 会拿一条没有人在执行的策略
    -- 去拒绝一个本来做得了决定的人。这与 HR 三条链的形状一致 ——
    -- ☞ 也正因为如此,一张 submitted 的报销单【不挡】审批关闭
    --   (approval_pending_documents 的 blocks_disable = false,理由写在那里)。
    IF v_appr_on THEN
        SELECT b.amount_base INTO v_base FROM expense_claim_amount_base(p_claim_id) b;
        IF v_base IS NULL THEN
            -- 【那句话归 fx_rate_for 所有,这里只是把它请出来】——
            -- 自己拼一句 FX_RATE_MISSING 就是这条 FX 规矩的第二份定义。
            PERFORM fx_rate_for(v_c.currency, v_c.spend_date, 'tt_sell');
            -- 上面必定抛;真走到这里说明牌价其实查得到而上一步算出了 NULL,
            -- 那是一个【不该发生】的状态,按名拒而不是继续往下走。
            RAISE EXCEPTION 'EXPENSE_CLAIM_AMOUNT_BASE_UNRESOLVED|%', v_c.code;
        END IF;
        v_level := approval_level_for(v_base);
        PERFORM require_approver_for(v_level);
    END IF;

    -- ══ 驳回 ══════════════════════════════════════════════════════════════
    IF NOT p_approve THEN
        -- 【按名拒,而不是让 CHECK 抛约束原文】fixture 90 立的那条
        IF p_notes IS NULL OR btrim(p_notes) = '' THEN
            RAISE EXCEPTION 'EXPENSE_CLAIM_REJECT_REASON_REQUIRED|%', v_c.code;
        END IF;
        UPDATE expense_claims
           SET status = 'rejected', decided_at = now(), decided_by = auth.uid(),
               decision_notes = btrim(p_notes)
         WHERE id = p_claim_id;
        -- ★ 驳回【也】留痕 —— APR-1 建这张表的第一条理由就是"驳回 → 重提 →
        --   批准之后,驳回那一次不留痕迹"。报销单此前正是那个形状:
        --   decision_notes 会被下一次决定覆盖掉。
        PERFORM record_approval_decision('expense_claim', p_claim_id, 'rejected',
                                         v_level, btrim(p_notes));
        RETURN jsonb_build_object('claim_id', p_claim_id, 'code', v_c.code, 'status', 'rejected',
                                  'level', v_level);
    END IF;

    -- ══ 批准 ══════════════════════════════════════════════════════════════
    IF p_account_code IS NULL OR btrim(p_account_code) = '' THEN
        -- 会计口径由审批人给 —— 没有科目就没法记账,而猜一个科目比拒绝坏
        RAISE EXCEPTION 'EXPENSE_CLAIM_ACCOUNT_REQUIRED|%', v_c.code;
    END IF;

    -- ★【GST 开着时,税码是【必给】的 —— 而且只能由审批人给】★
    -- 实测:resolve_tax_code 接受 override 或【往来对象的默认税码】,两者皆空就
    -- 按名拒(TAX_CODE_REQUIRED)。而 employees **没有 default_tax_code 这一列** ——
    -- 员工这一侧【永远】解析不出默认值。所以报销这条路上,税码只能显式给。
    -- 【为什么在这里先拒一次,而不是让 resolve_tax_code 去拒】它的提示语是
    -- 「给这个往来对象设一个默认税码,或在这张单据上指定一个」—— 对员工来说
    -- 前半句是【做不到的事】,于是那句话有一半是错的指路。这里按名拒并说清楚
    -- 要做的判断:进项税可抵是 TX,不可抵是 BL,而那是一个财务判断。
    -- 【这不是把税的规矩重写一遍】有效性、侧别、是否停用仍然全归 resolve_tax_code;
    -- 这里只声明一个【这条路特有的前提】:员工没有默认值,所以 override 必填。
    IF (SELECT gst_registered FROM finance_settings) AND
       COALESCE(btrim(COALESCE(p_tax_code, '')), '') = '' THEN
        RAISE EXCEPTION 'EXPENSE_CLAIM_TAX_CODE_REQUIRED|%', v_c.code;
    END IF;

    -- ★【凭据:要么有附件,要么有一句说得出为什么没有】★
    -- 【为什么查在这一步而不是提交那一步】提交那一刻申请还不存在,附件挂不上去;
    -- 而凭据真正起作用的时刻,正是有人要据它做决定的时刻。
    -- 【为什么留了一条例外的路】一条没有例外出口的规矩会被绕过 ——
    -- 这里绕过的走法是"让财务当成一笔普通费用直接录进去",而那会把整条
    -- 报销记录一起丢掉。所以:允许没有收据,但要求把【为什么】说出来,
    -- 并且让审批人看见自己批的是哪一种。
    SELECT EXISTS (SELECT 1 FROM finance_attachments
                    WHERE claim_id = p_claim_id AND deleted_at IS NULL) INTO v_has_att;
    IF NOT v_has_att AND COALESCE(btrim(v_c.no_receipt_reason), '') = '' THEN
        RAISE EXCEPTION 'EXPENSE_CLAIM_NO_EVIDENCE|%', v_c.code;
    END IF;

    -- 入账日:默认花钱那天;期间关了账时由审批人显式给
    v_date := COALESCE(p_posting_date, v_c.spend_date);

    -- 【成本与欠款在这里同时落地】unpaid = 一笔挂在这名员工头上的应付,
    -- 它会立刻出现在 ap_open_items 里带着他自己的名字(PAYEE-1a)。
    -- 汇率传 NULL:由 record_expense 按【那一天】自己查牌价 —— 一条 FX 规矩,
    -- 查不到就按名拒(FX_RATE_MISSING),报销不是它的例外。
    -- ⚠ APR-3 照直说:这里过账取的是 v_date 那天的牌价,而上面分档取的是
    --   spend_date 那天的 —— 两个日期不同时,两个数可以不一样。那是两个不同的
    --   问题(这笔承诺有多大 / 账上记多少),理由写在 expense_claim_amount_base。
    -- ★★【这张开支单【不】另外走一次审批】它是引擎在一个人已经批准之后代他
    --   记的账,不是一份新提交的单据 —— 与 N5 对系统生成凭证的裁定逐字同源。
    --   expense 这个 subject_type 在 APR-3 里【没有】接上引擎(Tim 的 Q2 裁定:
    --   payments / expenses 没有在途态,要先做一次建模改动),所以今天这一格
    --   不需要任何豁免机制;那条路开工时,豁免要写成一个【显式入参】,不是 GUC
    --   (Tim 的 Q9),理由记在 docs/forward-queue.md。
    v_exp := record_expense(
        p_expense_date   := v_date,
        p_account_code   := btrim(p_account_code),
        p_amount         := v_c.amount_ccy,
        p_currency       := v_c.currency,
        p_fx_rate        := NULL,
        p_payment_status := 'unpaid',
        p_bank_account   := NULL,
        p_supplier_id    := NULL,
        p_employee_id    := v_c.employee_id,
        p_payee_name     := v_emp.legal_name,
        p_notes          := format('Expense claim %s (%s) — %s', v_c.code, v_emp.code, v_c.description),
        p_tax_code       := NULLIF(btrim(COALESCE(p_tax_code, '')), ''),
        -- CLAIM-GST-1(Tim Q3):员工报上来的是【收据上的总额】,已含 GST —— 税从里面拆出来,不加在上面。
        p_amount_includes_tax := true);

    UPDATE expense_claims
       SET status = 'approved', decided_at = now(), decided_by = auth.uid(),
           decision_notes = NULLIF(btrim(COALESCE(p_notes, '')), ''),
           account_code = btrim(p_account_code),
           tax_code = NULLIF(btrim(COALESCE(p_tax_code, '')), ''),
           posting_date = v_date,
           expense_id = (v_exp->>'expense_id')::uuid
     WHERE id = p_claim_id;

    PERFORM record_approval_decision('expense_claim', p_claim_id, 'approved',
                                     v_level, NULLIF(btrim(COALESCE(p_notes, '')), ''));

    RETURN jsonb_build_object('claim_id', p_claim_id, 'code', v_c.code, 'status', 'approved',
                              'expense_id', v_exp->>'expense_id', 'posting_date', v_date,
                              'level', v_level);
END;
$function$;

-- ═══ db/functions/pay_medical_claim.sql ═══
CREATE OR REPLACE FUNCTION public.pay_medical_claim(p_claim_id uuid, p_expense_date date DEFAULT NULL::date, p_fx_rate numeric DEFAULT NULL::numeric, p_tax_code text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_claim record;
    v_emp   record;
    v_exp   jsonb;
    v_code  text;
    v_date  date;
    v_fx    numeric;
    v_tax   text;
BEGIN
    PERFORM require_permission('module.finance.edit');
    IF p_expense_date IS NULL THEN
        RAISE EXCEPTION 'EXPENSE_DATE_REQUIRED';
    END IF;
    v_date := p_expense_date;

    SELECT * INTO v_claim FROM medical_claims WHERE id = p_claim_id AND deleted_at IS NULL FOR UPDATE;
    IF NOT FOUND THEN RAISE EXCEPTION 'CLAIM_NOT_FOUND'; END IF;

    -- HR 那一半的把关:必须已经被批准过
    IF v_claim.status <> 'approved' THEN
        RAISE EXCEPTION 'CLAIM_NOT_APPROVED|%', v_claim.status;
    END IF;

    IF v_claim.expense_id IS NOT NULL THEN
        SELECT code INTO v_code FROM expenses WHERE id = v_claim.expense_id;
        RAISE EXCEPTION 'CLAIM_ALREADY_PAID|%', COALESCE(v_code, v_claim.expense_id::text);
    END IF;

    SELECT id, code, legal_name INTO v_emp FROM employees WHERE id = v_claim.employee_id;

    -- ── PAYEE-1a:上面那段"建一个 Staff Reimbursements 往来户"的注释【已退休】──
    -- 它原本写着:"expenses 的 CHECK 要求 unpaid 时 supplier_id 非空(应付账上
    -- 总得有'付给谁')。员工不是供应商,所以实务上建一个往来户,具体是谁写在
    -- payee_name 与备注里。" —— 那段话准确描述了一个【真实存在过的】变通,
    -- 而本刀移除了它的必要性:expenses 现在收得下 employee_id,应付账按人分行。
    -- 【注释与它描述的东西一起退休】—— 一条描述着已不存在的约束的注释,
    -- 与一条断言着不可能发生的隐患的注释是同一个缺陷(AGENTS.md)。
    -- 报销的收款人【就是提交报销的那个员工】,不需要任何人再挑一次。

    -- FIN-0:报销是 SGD,账本也是 SGD —— 不再需要任何汇率。
    -- (旧版在这里取"当天或之前最近"的一条汇率;那正是 C5 要禁掉的写法,随基准换币一并拆除。)
    IF p_fx_rate IS NOT NULL AND p_fx_rate <> 1 THEN
        RAISE EXCEPTION 'FX_RATE_NOT_ACCEPTED|SGD';
    END IF;
    v_fx := 1;

    -- ★★ BUGFIX-1b:【GST 开着时税码必给,而且只能由人显式给】★★
    -- 【为什么在这里先拒,而不是让 resolve_tax_code 去拒】它的 HINT 写着
    -- 「给这个往来对象设一个默认税码,或在这张单据上指定一个」—— 对员工报销来说
    -- **前半句是做不到的事**(employees 没有 default_tax_code),而这条路上
    -- 连一个往来对象都没有。于是那句指路有一半是错的,而且它的码 `|supplier`
    -- 指的方向也是错的。这里按名拒,并且拿【这张报销单的单号】做参数,
    -- 让界面能说出"哪一张"。与 decide_expense_claim 的 EXPENSE_CLAIM_TAX_CODE_REQUIRED
    -- 逐字同一个形状。
    -- ★ GST 关着时【什么都不做】:record_expense 在未注册时对一个非空税码是
    --   **按名拒**(GST_NOT_REGISTERED),所以这里既不要求也不伪造。
    v_tax := NULLIF(btrim(COALESCE(p_tax_code, '')), '');
    IF gst_registered() AND v_tax IS NULL THEN
        RAISE EXCEPTION 'MEDICAL_CLAIM_TAX_CODE_REQUIRED|%', v_claim.code;
    END IF;

    v_exp := record_expense(
        p_expense_date  := v_date,
        p_account_code  := '6120',
        p_amount        := v_claim.amount_sgd,
        p_currency      := 'SGD',
        p_fx_rate       := NULL,
        p_payment_status:= 'unpaid',
        p_bank_account  := NULL,
        p_supplier_id   := NULL,
        p_employee_id   := v_claim.employee_id,
        p_payee_name    := v_emp.legal_name,
        p_notes         := format('Medical claim %s (%s)', v_claim.code, v_emp.code),
        p_tax_code      := v_tax,
        -- CLAIM-GST-1(Tim Q3):员工报上来的是【收据上的总额】,已含 GST —— 税从里面拆出来,不加在上面。
        p_amount_includes_tax := true);

    -- 【状态仍然是 approved,不是 paid】。
    -- 这笔费用刚建出来是 unpaid —— 员工手里一分钱还没拿到。此刻把报销标成
    -- "paid" 是在说一件没发生的事。真正的结清由付款流程完成,
    -- medical_claim_status 视图从 expenses.payment_status 推导出真实状态。
    UPDATE medical_claims
    SET expense_id = (v_exp->>'expense_id')::uuid, updated_by = auth.uid()
    WHERE id = p_claim_id;

    RETURN jsonb_build_object(
        'claim_id', p_claim_id, 'claim_code', v_claim.code,
        'expense_id', v_exp->>'expense_id', 'expense_code', v_exp->>'code',
        'account_code', '6120', 'amount_sgd', v_claim.amount_sgd, 'fx_rate', v_fx,
        'tax_code', v_tax,
        'payment_status', 'unpaid',
        'claim_status', 'approved',
        'note', 'An unpaid expense has been raised. The claim becomes settled when that expense is paid through the payment flow; it is not marked paid on creation.');
END;
$function$;

COMMENT ON FUNCTION public.pay_medical_claim(uuid, date, numeric, text) IS
'把已批准的医疗报销变成一笔未付费用(6120)。GST 开着时 p_tax_code 必给 —— 员工没有默认税码,所以只能由人显式选。★ 走哪个税码是一条【政策】,写在 docs/accounting-policies.md §9.1b(一般规则:新加坡 GST Reg 26 把员工医疗开支的进项税挡住,即 BL;界面预选 BL 但仍要人确认;截至 2026-09-12 该规则尚未经会计确认)。允许的进项税码只有一处真源:tax_codes 里 is_active 且 side=''input'' 的那些,与 decide_expense_claim 那条路同源。';

-- ═══ db/functions/ap_aging_asof.sql ═══
CREATE OR REPLACE FUNCTION public.ap_aging_asof(p_as_of date DEFAULT CURRENT_DATE)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_as_of    date;
    v_today    date := CURRENT_DATE;
    v_start    date;
    v_base     text;
    v_rows     jsonb;
    v_buckets  jsonb;
    v_total    numeric;
    v_unpriced integer;
BEGIN
    -- 没有财务模块 → 【按名拒绝】,不是 0 行。两张老视图给的是 0 行
    -- (视图没有别的表达方式),而 0 行在页面上读作「没有未结单据」——
    -- 一句假话。函数有更好的表达方式,就该用。
    PERFORM require_permission('module.finance.view');

    -- 只读查询的"截至哪天",默认今天 —— 与 leave_balance / accrued_annual_leave
    -- 一族同一个惯用法,并已记在 docs/empty-string-to-rpc-audit.md 的白名单里。
    -- 【它不是那条"不许给日期默认值"的规矩的例外,是那条规矩的射程之外】:
    -- 那条管的是决定汇率、期间、金额的【写入】日期,而这里什么都不写。
    v_as_of := COALESCE(p_as_of, v_today);

    IF v_as_of > v_today THEN
        RAISE EXCEPTION 'AGING_AS_OF_FUTURE|%|%', v_as_of, v_today;
    END IF;

    SELECT fs.system_start_date INTO v_start FROM finance_settings fs LIMIT 1;
    SELECT c.code INTO v_base FROM currencies c WHERE c.is_base;

    SELECT COALESCE(jsonb_agg(to_jsonb(x) ORDER BY x.doc_date, x.doc_code), '[]'::jsonb)
      INTO v_rows
      FROM (
        -- ── 支一:已计价、在册的进料批次 ────────────────────────────────
        SELECT 'inbound'::text                                   AS doc_kind,
               ib.id                                             AS doc_id,
               ib.code                                           AS doc_code,
               ib.id                                             AS inbound_batch_id,
               ib.supplier_id                                    AS supplier_id,
               sup.legal_name                                    AS supplier_name,
               COALESCE(ib.arrival_date, ib.created_at::date)    AS doc_date,
               NULL::date                                        AS due_date,
               round(ib.quantity * pr.price, 2)                  AS doc_value_base,
               round(COALESCE(s.settled, 0) + COALESCE(pp.applied, 0), 2) AS settled_base,
               round(round(ib.quantity * pr.price, 2)
                     - COALESCE(s.settled, 0) - COALESCE(pp.applied, 0), 2) AS open_base,
               v_base                                            AS currency,
               round(round(ib.quantity * pr.price, 2)
                     - COALESCE(s.settled, 0) - COALESCE(pp.applied, 0), 2) AS open_ccy,
               (v_as_of - COALESCE(ib.arrival_date, ib.created_at::date))   AS days_outstanding,
               aging_bucket(v_as_of - COALESCE(ib.arrival_date, ib.created_at::date)) AS bucket,
               'supplier'::text                                  AS counterparty_kind,
               ib.supplier_id                                    AS counterparty_id,
               sup.legal_name                                    AS counterparty_name
          FROM inbound_batches_masked ib
          JOIN suppliers sup ON sup.id = ib.supplier_id
          -- 价格:D 那天的价,再套上与 inbound_batches_masked.unit_price
          -- 【逐字同源】的那道 data.view_prices 遮罩(见抬头)。
          CROSS JOIN LATERAL (
                SELECT CASE WHEN has_permission('data.view_prices')
                            THEN inbound_unit_price_asof(ib.id, v_as_of)
                       END AS price
          ) pr
          LEFT JOIN LATERAL (
                SELECT sum(pa.allocated_ccy) AS settled
                  FROM payment_allocations pa
                  JOIN payments p ON p.id = pa.payment_id
                  LEFT JOIN payments rev ON rev.id = p.reversed_by_payment
                 WHERE pa.inbound_batch_id = ib.id
                   AND p.payment_date <= v_as_of
                   AND (p.status = 'posted'
                        OR (p.status = 'reversed' AND rev.payment_date > v_as_of))
          ) s ON true
          LEFT JOIN LATERAL (
                SELECT sum(ppa.amount_base) AS applied
                  FROM prepayment_applications_masked ppa
                  LEFT JOIN journal_entries je ON je.id = ppa.journal_entry_id
                 WHERE ppa.inbound_batch_id = ib.id
                   AND COALESCE(je.entry_date, ppa.created_at::date) <= v_as_of
          ) pp ON true
         WHERE (ib.deleted_at IS NULL OR ib.deleted_at::date > v_as_of)
           AND COALESCE(ib.arrival_date, ib.created_at::date) <= v_as_of
           AND pr.price IS NOT NULL

        UNION ALL

        -- ── 支二:挂账开支 ─────────────────────────────────────────────
        SELECT 'expense'::text, e.id, e.code, NULL::uuid,
               e.supplier_id, sup.legal_name,
               e.expense_date, NULL::date,
               -- AP-RECON-1:净额 + 进项税,与 ap_open_items 费用支逐字同一套(见该视图抬头)。
               e.amount_base + COALESCE(e.tax_base, 0),
               round((COALESCE(s.settled, 0) + COALESCE(pp.applied, 0)) * e.fx_rate, 2),
               CASE WHEN (COALESCE(s.settled, 0) + COALESCE(pp.applied, 0)) = 0
                    THEN e.amount_base + COALESCE(e.tax_base, 0)
                    ELSE round((e.amount_ccy + e.tax_ccy - COALESCE(s.settled, 0) - COALESCE(pp.applied, 0)) * e.fx_rate, 2)
               END,
               e.currency,
               round(e.amount_ccy + e.tax_ccy - COALESCE(s.settled, 0) - COALESCE(pp.applied, 0), 2),
               (v_as_of - e.expense_date),
               aging_bucket(v_as_of - e.expense_date),
               CASE WHEN e.employee_id IS NOT NULL THEN 'employee' ELSE 'supplier' END::text,
               COALESCE(e.supplier_id, e.employee_id),
               COALESCE(sup.legal_name, emp.legal_name)
          FROM expenses e
          LEFT JOIN suppliers sup ON sup.id = e.supplier_id
          LEFT JOIN employees emp ON emp.id = e.employee_id
          LEFT JOIN LATERAL (
                SELECT sum(pa.allocated_ccy) AS settled
                  FROM payment_allocations pa
                  JOIN payments p ON p.id = pa.payment_id
                  LEFT JOIN payments rev ON rev.id = p.reversed_by_payment
                 WHERE pa.expense_id = e.id
                   AND p.payment_date <= v_as_of
                   AND (p.status = 'posted'
                        OR (p.status = 'reversed' AND rev.payment_date > v_as_of))
          ) s ON true
          LEFT JOIN LATERAL (
                SELECT sum(ppa.amount_ccy) AS applied
                  FROM prepayment_applications_masked ppa
                  LEFT JOIN journal_entries je ON je.id = ppa.journal_entry_id
                 WHERE ppa.expense_id = e.id
                   AND COALESCE(je.entry_date, ppa.created_at::date) <= v_as_of
          ) pp ON true
         WHERE e.expense_date <= v_as_of
           -- 【为什么 payment_status 这个"现在"的标志还留着,而且必须留着】
           -- 实测:EXP-2026-0002 与 EXP-2026-0005 是 payment_status='paid' 却
           -- 【一条核销行都没有】—— 它们是当场付掉的,那笔钱根本不走 allocation。
           -- 所以"已付"在这套系统里【推导不出来】,只有那个标志说得出来。
           -- 于是判据写成:今天还挂着账 【或者】 它的结清发生在 D 【之后】。
           -- D = 今天时,后半永远为假(没有晚于今天的收付款 —— 实测 0 笔),
           -- 于是它逐字退化成今天那张视图的 `payment_status='unpaid'`。
           -- 这就是"默认今天等于今天的行为"在这一支上的落点。
           AND (e.payment_status = 'unpaid'
                OR EXISTS (SELECT 1 FROM payment_allocations pa2
                             JOIN payments p2 ON p2.id = pa2.payment_id
                            WHERE pa2.expense_id = e.id AND p2.payment_date > v_as_of)
                OR EXISTS (SELECT 1 FROM prepayment_applications ppa2
                             LEFT JOIN journal_entries je2 ON je2.id = ppa2.journal_entry_id
                            WHERE ppa2.expense_id = e.id
                              AND COALESCE(je2.entry_date, ppa2.created_at::date) > v_as_of))
           -- 单据在 D 那天【站着没有】:今天 posted 的站着;今天是 reversed 的,
           -- 若那次冲销发生在 D 之后,它在 D 那天也是站着的。
           AND (e.status = 'posted'
                OR (e.status = 'reversed'
                    AND (SELECT m.expense_date FROM expenses m
                          WHERE m.id = e.reversed_by_expense) > v_as_of))
           -- 镜像行照旧排除(它是冲销的记账凭证,不是一张新的应付单)
           AND NOT EXISTS (SELECT 1 FROM expenses o WHERE o.reversed_by_expense = e.id)

        UNION ALL

        -- ── 支三:未付运费单 ───────────────────────────────────────────
        SELECT 'freight'::text, fd.id, fd.code, NULL::uuid,
               fd.supplier_id, sup.legal_name,
               fd.doc_date, NULL::date,
               fd.amount_base,
               round(COALESCE(s.settled, 0) * fd.fx_rate, 2),
               round((fd.amount_ccy - COALESCE(s.settled, 0)) * fd.fx_rate, 2),
               fd.currency,
               round(fd.amount_ccy - COALESCE(s.settled, 0), 2),
               (v_as_of - fd.doc_date),
               aging_bucket(v_as_of - fd.doc_date),
               'supplier'::text, fd.supplier_id, sup.legal_name
          FROM freight_documents fd
          JOIN suppliers sup ON sup.id = fd.supplier_id
          LEFT JOIN LATERAL (
                SELECT sum(pa.allocated_ccy) AS settled
                  FROM payment_allocations pa
                  JOIN payments p ON p.id = pa.payment_id
                  LEFT JOIN payments rev ON rev.id = p.reversed_by_payment
                 WHERE pa.freight_document_id = fd.id
                   AND p.payment_date <= v_as_of
                   AND (p.status = 'posted'
                        OR (p.status = 'reversed' AND rev.payment_date > v_as_of))
          ) s ON true
         WHERE fd.doc_date <= v_as_of
           AND (fd.deleted_at IS NULL OR fd.deleted_at::date > v_as_of)
           AND (fd.payment_status = 'unpaid'
                OR EXISTS (SELECT 1 FROM payment_allocations pa2
                             JOIN payments p2 ON p2.id = pa2.payment_id
                            WHERE pa2.freight_document_id = fd.id AND p2.payment_date > v_as_of))
           -- 运费单的冲销日:优先取【冲销分录的分录日】(那是业务日),
           -- 取不到才退回 reversed_at 的录入时刻。与 reverse_freight_document
           -- 用 CURRENT_DATE 立那张冲销分录逐字对应。
           AND (fd.status = 'posted'
                OR (fd.status = 'reversed'
                    AND COALESCE((SELECT je.entry_date FROM journal_entries je
                                   WHERE je.id = fd.reversal_entry_id),
                                 fd.reversed_at::date) > v_as_of))
      ) x
     WHERE x.open_ccy > 0;

    -- 档位合计:四档【一档不落】,没有的那一档是 0 而不是缺席 ——
    -- 一个缺席的键在页面上会渲染成空白,读起来像"没算出来"。
    SELECT jsonb_object_agg(b.bucket, COALESCE(agg.total, 0))
      INTO v_buckets
      FROM (VALUES ('b0_30'), ('b31_60'), ('b61_90'), ('b90_plus')) AS b(bucket)
      LEFT JOIN LATERAL (
            SELECT round(sum((e->>'open_base')::numeric), 2) AS total
              FROM jsonb_array_elements(v_rows) e
             WHERE e->>'bucket' = b.bucket
      ) agg ON true;

    SELECT COALESCE(round(sum((e->>'open_base')::numeric), 2), 0)
      INTO v_total FROM jsonb_array_elements(v_rows) e;

    -- 【被"那天还没有价"挡掉的批次有几张】—— 一个缺席要说得出数目,
    -- 否则它与"本来就没有这笔应付"在屏幕上长得一模一样。
    -- 没有 data.view_prices 时这个数是 NULL 而不是 0:那不是"零张",
    -- 是"你看不到这一栏",与价格本身遮成 NULL 同一个道理。
    IF has_permission('data.view_prices') THEN
        SELECT count(*) INTO v_unpriced
          FROM inbound_batches ib
         WHERE (ib.deleted_at IS NULL OR ib.deleted_at::date > v_as_of)
           AND COALESCE(ib.arrival_date, ib.created_at::date) <= v_as_of
           AND inbound_unit_price_asof(ib.id, v_as_of) IS NULL;
    ELSE
        v_unpriced := NULL;
    END IF;

    RETURN jsonb_build_object(
        'side',                'ap',
        'as_of',               v_as_of,
        'today',               v_today,
        'is_past',             (v_as_of < v_today),
        'system_start_date',   v_start,
        'before_system_start', (v_start IS NOT NULL AND v_as_of < v_start),
        'base_currency',       v_base,
        -- 机器令牌,不是给人读的句子 —— 双语措辞留在 messages/,按语言选一条。
        'amount_basis',        'quantity_now_price_asof',
        'unpriced_excluded',   v_unpriced,
        'total_open_base',     v_total,
        'buckets',             v_buckets,
        'rows',                v_rows
    );
END;
$function$;

COMMENT ON FUNCTION public.ap_aging_asof(date) IS
    'AGING-1:AP 账龄【截至某一天】。视图接不了参数,而"截至"有四层而不是一层:① CURRENT_DATE 焊在视图体里;② 结清额要按付款日回推(晚于 D 的付款不算);③ 单据在 D 那天站着没有(D 之后的冲销/删除不回溯);④ 金额在 D 那天是多少(单价按 price_history 回推 —— 实测 2026-07-05 之前九张在开批次全部无价)。数量没有历史表,所以金额 = 今天的数量 × D 那天的价,由 amount_basis 明说。未来日期按名拒 AGING_AS_OF_FUTURE。截止日早于 system_start_date 不拒绝,返回 before_system_start 由页面与 CSV 各说一句(方向是把欠款报多)。p_as_of 默认今天,且【等于今天时逐行复现今天那张视图】—— db/fixtures/135 的 A 臂钉住。';

-- ═══ db/functions/record_payment_internal.sql ═══
CREATE OR REPLACE FUNCTION public.record_payment_internal(p_direction text, p_counterparty_id uuid, p_amount numeric, p_currency text, p_fx_rate numeric DEFAULT NULL::numeric, p_bank_account text DEFAULT NULL::text, p_payment_date date DEFAULT NULL::date, p_notes text DEFAULT NULL::text, p_allocations jsonb DEFAULT '[]'::jsonb, p_counterparty_kind text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_kind text;
    v_user         uuid := auth.uid();
    v_base         text;   -- OPS-8:本位币从 currencies.is_base 读
    v_date         date;
    v_fx           numeric;
    v_amount_base   numeric;
    v_doc_ccy      text;
    v_doc_fx       numeric;
    v_alloc_base   numeric;
    v_birth        numeric;   -- AP-RECON-1 Batch B:这张单过账时记下的本位币(清单未结时显示的就是它)
    v_base_total   numeric := 0;
    v_bank_base    numeric;
    v_unalloc_ccy  numeric;
    v_unalloc_base numeric;
    v_po_pay_base  numeric;
    v_realised     numeric;
    v_po_base      numeric := 0;
    v_bank         text;
    v_payment_id   uuid := gen_random_uuid();
    v_code         text;
    v_alloc        jsonb;
    v_sale_id      uuid;
    v_batch_id     uuid;
    v_expense_id   uuid;
    v_po_id        uuid;
    v_invoice_id   uuid;   -- SO-3a:订单流发票(第六种核销去处)
    v_freight_id   uuid;   -- PAY-FRT:运费单(第七个字段、第六种【付款侧】去处)
    v_alloc_usd    numeric;
    v_doc_rate     numeric;   -- 单据币种在【结算日】的牌价(折算用,不是单据入账汇率)
    v_alloc_pay    numeric;   -- 本条核销消耗掉多少【付款币种】
    v_alloc_pay_total numeric := 0;  -- Σ 消耗的付款币种额(与 p_amount 同币种比较)
    -- 控制科目要按【单据币种】逐币种发行:一笔付款可以同时结掉 USD 单和 SGD 单,
    -- 那就是两条解除行,各自的原币与各自的入账汇率。键 = 单据币种。
    v_ctrl         jsonb := '{}'::jsonb;   -- 结算类(1100 / 2000)
    v_pre          jsonb := '{}'::jsonb;   -- 预付类(1300)
    v_ccy_key      text;
    v_grp          record;
    v_doc          record;
    v_doc_value    numeric;
    v_settled      numeric;
    v_open         numeric;
    v_alloc_total  numeric := 0;
    v_je           jsonb;
    -- 拆账与两遍处理用
    v_key          text;
    v_running      jsonb := '{}'::jsonb;   -- 目标 id → 本笔内已累计核销额
    v_prior        numeric;
    v_valid        jsonb := '[]'::jsonb;   -- ①校验通过的核销行,②之后据此落库
    v_po_usd       numeric := 0;           -- 本笔中指向 PO 的预付合计(USD)
    v_ap_usd       numeric;
    v_po_ccy       numeric;
    v_ap_ccy       numeric;
    v_cap          numeric;
    v_delta        numeric;
    v_found        boolean;
    v_lines        jsonb;
    -- ── WHT-1:代扣 ──────────────────────────────────────────────────────
    -- ★【这是本函数唯一一处"贷方 ≠ 付出去的钱"的地方,而那正是代扣的定义】★
    --   供应商的债按【全额】解除(借 2000 不变),银行只走【净额】,
    --   差额贷 2150 —— 一笔对 IRAS 的负债。三个数,一条分录。
    v_wht_rate       numeric;          -- 本条核销所属债务冻下来的税率(每轮重置)
    v_wht_ccy        numeric;          -- 本条要扣多少,单据币种
    v_wht_pay        numeric;          -- 同上,折成付款币种(现金算术用)
    v_wht_base       numeric;          -- 同上,折成本位币 —— 【落库与入账用的是同一个数】
    v_wht_pay_total  numeric := 0;     -- Σ,付款币种
    v_wht_base_total numeric := 0;     -- Σ,本位币 —— 要汇给 IRAS 的那个数
    v_payee_residence text;            -- 出款对手方申报的税务居民身份
    v_has_wht_obligation boolean;      -- 这个对手方名下有没有【要代扣的】在册债务
BEGIN
    -- OPS-8:本位币是【数据】(currencies.is_base),不是字面量。
    SELECT c.code INTO v_base FROM currencies c WHERE c.is_base;
    -- ★ PAY-REQ-1:这里【没有】权限检查 —— 这支是内层引擎,EXECUTE 已从
    --   authenticated 收回(db/views/zzz_function_grants.sql)。门在两个外壳上:
    --   record_payment(finance.edit,且出款要么豁免、要么拒绝)与
    --   pay_payment_request(finance.edit,且只付一张已批准的申请)。
    --   dry-run 也走这里(payment_request_dry_run),所以 CFO 批准时能核对同一套规矩
    --   —— 而 CFO 不持 finance.edit。
    IF p_payment_date IS NULL THEN
        RAISE EXCEPTION 'PAYMENT_DATE_REQUIRED';
    END IF;
    v_date := p_payment_date;
    -- AP-RECON-1 Batch B(Tim AP-RECON-1 Q7):收付款是一件【已经发生】的事 —— 此前没有任何上界,日期晚于今天按名拒。
    IF v_date > CURRENT_DATE THEN
        RAISE EXCEPTION 'DOCUMENT_DATE_IN_FUTURE|payment|%|%', v_date, CURRENT_DATE;
    END IF;
    -- 1. 基础校验
    IF p_direction IS NULL OR p_direction NOT IN ('in','out') THEN
        RAISE EXCEPTION 'DIRECTION_INVALID|%', COALESCE(p_direction, '?');
    END IF;

    -- PAYEE-1a:往来对象【是哪一种】不再由 direction 推断,而是说出来的。
    -- 不填时退回本刀之前的默认('in'→客户,'out'→供应商),于是既有调用方一字不改。
    -- 【为什么不靠"在供应商里找不到就去员工里找"】那是一次静默回退:
    -- 打错一个 uuid 会从"找不到"变成"在另一张表里也找不到",错误信息指向错的地方;
    -- 而一个真的两边都存在的 id(理论上可能)会挑中谁,没有人说得清。
    v_kind := COALESCE(NULLIF(btrim(p_counterparty_kind), ''),
                       CASE WHEN p_direction = 'in' THEN 'customer' ELSE 'supplier' END);

    IF p_direction = 'in' AND v_kind <> 'customer' THEN
        RAISE EXCEPTION 'COUNTERPARTY_KIND_INVALID|%|%', p_direction, v_kind;
    END IF;
    IF p_direction = 'out' AND v_kind NOT IN ('supplier', 'employee') THEN
        RAISE EXCEPTION 'COUNTERPARTY_KIND_INVALID|%|%', p_direction, v_kind;
    END IF;

    IF v_kind = 'customer' THEN
        IF p_counterparty_id IS NULL OR NOT EXISTS (
            SELECT 1 FROM customers WHERE id = p_counterparty_id AND deleted_at IS NULL
        ) THEN
            RAISE EXCEPTION 'COUNTERPARTY_NOT_FOUND|%', COALESCE(p_counterparty_id::text, '?');
        END IF;
    ELSIF v_kind = 'supplier' THEN
        IF p_counterparty_id IS NULL OR NOT EXISTS (
            SELECT 1 FROM suppliers WHERE id = p_counterparty_id AND deleted_at IS NULL
        ) THEN
            RAISE EXCEPTION 'COUNTERPARTY_NOT_FOUND|%', COALESCE(p_counterparty_id::text, '?');
        END IF;
        -- WHT-1:出款对手方申报的税务居民身份。**只用来决定要不要【拦】** ——
        -- 实际扣多少一律读债务上冻下来的税率,不读这一列。一个已经记下的裁定
        -- 不能因为供应商今天改了身份就变一个数(见 expenses.wht_payee_residence)。
        SELECT tax_residence INTO v_payee_residence
        FROM suppliers WHERE id = p_counterparty_id;
    ELSE
        IF p_counterparty_id IS NULL OR NOT EXISTS (
            SELECT 1 FROM employees WHERE id = p_counterparty_id AND deleted_at IS NULL
        ) THEN
            RAISE EXCEPTION 'COUNTERPARTY_NOT_FOUND|%', COALESCE(p_counterparty_id::text, '?');
        END IF;
    END IF;

    IF p_amount IS NULL OR p_amount <= 0 THEN
        RAISE EXCEPTION 'AMOUNT_INVALID';
    END IF;
    IF p_currency IS NULL OR NOT EXISTS (SELECT 1 FROM currencies c WHERE c.code = p_currency) THEN
        RAISE EXCEPTION 'CURRENCY_INVALID|%', COALESCE(p_currency, '?');
    END IF;
    -- FIN-0 三分支:
    --   本位币                     → 1,无换算;
    --   外币、且走该币种的外币户   → 没有发生兑换,按【付款日】牌价估值:
    --                                收款 tt_buy / 付款 tt_sell,当日无牌价即拒;
    --   外币、但走的不是该币种的户 → 银行【实际做了兑换】,必须递入按银行水单
    --                                实际金额折出的汇率(C4:实际兑换用实际数,
    --                                永远不用牌价);此时 p_fx_rate 必填。
    IF p_currency = v_base THEN
        IF p_fx_rate IS NOT NULL THEN
            RAISE EXCEPTION 'FX_RATE_NOT_ACCEPTED|%', p_currency;
        END IF;
        v_fx := 1;
    ELSIF bank_native_currency(COALESCE(p_bank_account,
              bank_account_for_currency(p_currency))) = p_currency THEN
        IF p_fx_rate IS NOT NULL THEN
            RAISE EXCEPTION 'FX_RATE_NOT_ACCEPTED|%', p_currency;
        END IF;
        v_fx := fx_rate_for(p_currency, v_date,
                            CASE WHEN p_direction = 'in' THEN 'tt_buy' ELSE 'tt_sell' END);
    ELSE
        IF p_fx_rate IS NULL THEN
            RAISE EXCEPTION 'FX_RATE_REQUIRED|%', p_currency;
        END IF;
        IF p_fx_rate <= 0 THEN
            RAISE EXCEPTION 'FX_RATE_INVALID|%', p_fx_rate;
        END IF;
        v_fx := p_fx_rate;
    END IF;

    -- 银行科目:显式给了必须合法;不给按币种默认 —— 映射只有一份
    -- (bank_account_for_currency,bank_native_currency 的逆;同 lib/currencyMap.ts)
    IF p_bank_account IS NOT NULL THEN
        IF p_bank_account NOT IN ('1000','1010') THEN
            RAISE EXCEPTION 'BANK_INVALID|%', p_bank_account;
        END IF;
        v_bank := p_bank_account;
    ELSE
        v_bank := bank_account_for_currency(p_currency);
    END IF;

    -- 2. USD 金额
    v_amount_base := round(p_amount * v_fx, 2);

    IF p_allocations IS NULL OR jsonb_typeof(p_allocations) <> 'array' THEN
        RAISE EXCEPTION 'ALLOC_INVALID|not_an_array';
    END IF;

    -- ========================================================================
    -- ① 核销行:逐条校验,不落库。顺序:存在 → 归属 → 计价 → 敞口。
    --    'in' 只认 sales_record_id / invoice_id;'out' 认 inbound_batch_id /
    --    expense_id / purchase_order_id(预付)/ freight_document_id(运费,PAY-FRT)。
    -- ========================================================================
    FOR v_alloc IN SELECT * FROM jsonb_array_elements(p_allocations)
    LOOP
        v_sale_id    := (v_alloc->>'sales_record_id')::uuid;
        v_batch_id   := (v_alloc->>'inbound_batch_id')::uuid;
        v_expense_id := (v_alloc->>'expense_id')::uuid;
        v_po_id      := (v_alloc->>'purchase_order_id')::uuid;
        v_invoice_id := (v_alloc->>'invoice_id')::uuid;
        v_freight_id := (v_alloc->>'freight_document_id')::uuid;
        v_alloc_usd  := (v_alloc->>'amount_doc')::numeric;  -- FIN-2:单据币种金额
        -- 【每一轮重置】v_doc 是一个跨臂复用的 record,各臂 SELECT 出来的形状
        -- 并不相同 —— 所以代扣税率不能挂在 v_doc 上读,必须由本变量逐轮携带。
        -- 不重置的话,上一条要代扣的核销会把税率漏给下一条不该代扣的核销,
        -- 而那是一个算得出数、不报错的错误。
        v_wht_rate := NULL;

        IF v_alloc_usd IS NULL OR v_alloc_usd <= 0
           OR num_nonnulls(v_sale_id, v_batch_id, v_expense_id, v_po_id, v_invoice_id,
                           v_freight_id) <> 1 THEN
            RAISE EXCEPTION 'ALLOC_INVALID|%', v_alloc::text;
        END IF;

        IF p_direction = 'in' THEN
            IF v_batch_id IS NOT NULL OR v_expense_id IS NOT NULL OR v_po_id IS NOT NULL
               OR v_freight_id IS NOT NULL THEN
                RAISE EXCEPTION 'ALLOC_WRONG_SIDE';
            END IF;
            IF v_invoice_id IS NOT NULL THEN
                -- ════════════════════════════════════════════════════════════
                -- SO-3a:订单流发票 —— 它自己就是应收单据(开票即 借1100/贷2500)。
                -- doc_value = Σ 明细行 amount_ccy(生成列,与 order_invoice_open_all
                -- 同口径);doc_fx = 发票【存下来的】入账汇率(从订单抄来的那一个)
                -- —— 结算按它解除,已实现汇兑(7100)也从它算起。开屏现查一个
                -- "今天的"汇率,会让同一张发票每天欠不一样的钱。
                -- 只认 kind='order' 且在册:sale 头的应收在 sales_records 上,
                -- 拿它的发票来核销就是同一笔债的第二个入口(ALLOC_INVALID)。
                -- ════════════════════════════════════════════════════════════
                -- ════════════════════════════════════════════════════════════
                -- AP-RECON-1(Tim AP-RECON-1 Q5):sale 型发票的【销项税】是它自己的
                -- 一项应收。create_invoice 在开票时借 1100 那一笔税(以本位币,即便
                -- 销售是 USD),而销售记录的上限只认 数量×单价 —— 那笔税此前没有任何
                -- 入口能收。所以 sale 型发票现在【只作为它那笔税】被核销:
                --   doc_value = invoices.tax_base(过账时存下的那个数),币种 = 本位币,
                --   汇率 = 1。净额仍然只在销售记录上收 —— 同一笔债不开第二个入口,
                --   上面那段话的原意不变,变的只是"税"这一笔此前根本没有入口。
                -- 不带税的 sale 型发票照旧 ALLOC_INVALID。
                -- ════════════════════════════════════════════════════════════
                SELECT i.id, i.code AS doc_code, i.customer_id AS party_id,
                       -- AP-RECON-1 Batch B:订单发票欠的 = 净额 + 销项税(order_invoice_balance_all,
                       -- 清单、账龄、敞口、贷项凭证天花板读的同一处)。此前只认 Σ 明细行,
                       -- 一张带税的订单发票那笔税永远收不进来。
                       CASE WHEN i.kind = 'order' THEN b.amount_ccy
                            ELSE i.tax_base END AS doc_value,
                       CASE WHEN i.kind = 'order' THEN i.currency ELSE v_base END AS doc_ccy,
                       CASE WHEN i.kind = 'order' THEN i.fx_rate ELSE 1::numeric END AS doc_fx,
                       -- AP-RECON-1 Batch B:过账时 1100 上为它记下的本位币 —— 订单发票是净额腿
                       -- round(Σ行 × 汇率) + 税那条腿 tax_base;sale 型发票的那一笔就是 tax_base。
                       CASE WHEN i.kind = 'order' THEN b.birth_base
                            ELSE i.tax_base END AS birth_base,
                       i.kind AS inv_kind, b.credited_ccy AS credited_ccy
                INTO v_doc
                FROM invoices i
                LEFT JOIN order_invoice_balance_all b ON b.invoice_id = i.id
                WHERE i.id = v_invoice_id AND i.status = 'issued'
                  AND (i.kind = 'order' OR (i.kind = 'sale' AND i.tax_base > 0));
                IF NOT FOUND THEN
                    RAISE EXCEPTION 'ALLOC_INVALID|%', v_invoice_id;
                END IF;
                IF v_doc.party_id IS DISTINCT FROM p_counterparty_id THEN
                    RAISE EXCEPTION 'ALLOC_WRONG_PARTY|%', v_doc.doc_code;
                END IF;
                v_doc_value := v_doc.doc_value;
                v_doc_ccy := v_doc.doc_ccy; v_doc_fx := v_doc.doc_fx;
                v_birth := v_doc.birth_base;
                v_key := v_invoice_id::text;

                SELECT COALESCE(SUM(pa.allocated_ccy), 0) INTO v_settled
                FROM payment_allocations pa
                JOIN payments p ON p.id = pa.payment_id AND p.status = 'posted'
                WHERE pa.invoice_id = v_invoice_id;
                -- AP-RECON-1 Batch B:贷项凭证也在减这张订单发票的欠款 —— order_invoice_balance_all
                -- (清单、账龄、敞口读的那一处)一直是 金额 − 已收 − 已贷记。只有这里漏了它:
                -- 开过贷项凭证之后,收款上限仍按没贷记之前算,解除额也就对不上清单。
                IF v_doc.inv_kind = 'order' THEN
                    v_settled := v_settled + COALESCE(v_doc.credited_ccy, 0);
                END IF;
            ELSE
                SELECT sr.id, ob.code AS doc_code, sr.customer_id AS party_id,
                       round(sr.quantity * sr.unit_price, 2) AS doc_value,
                       sr.currency AS doc_ccy, sr.fx_rate AS doc_fx,
                       sr.amount_base AS birth_base
                INTO v_doc
                FROM sales_records sr
                JOIN output_batches ob ON ob.id = sr.output_batch_id
                WHERE sr.id = v_sale_id;
                IF NOT FOUND THEN
                    RAISE EXCEPTION 'ALLOC_INVALID|%', v_sale_id;
                END IF;
                IF v_doc.party_id IS DISTINCT FROM p_counterparty_id THEN
                    RAISE EXCEPTION 'ALLOC_WRONG_PARTY|%', v_doc.doc_code;
                END IF;
                v_doc_value := v_doc.doc_value;
                v_doc_ccy := v_doc.doc_ccy; v_doc_fx := v_doc.doc_fx;
                v_birth := v_doc.birth_base;
                v_key := v_sale_id::text;

                SELECT COALESCE(SUM(pa.allocated_ccy), 0) INTO v_settled
                FROM payment_allocations pa
                JOIN payments p ON p.id = pa.payment_id AND p.status = 'posted'
                WHERE pa.sales_record_id = v_sale_id;
            END IF;

        ELSIF v_po_id IS NOT NULL THEN
            -- 预付款:PO 上【没有敞口上限】—— 定金不是在还债,那一刻还没有债。
            -- 唯一的栏杆是"累计预付不得超过估算总额 × 1.5",防手滑多打一个零。
            SELECT po.id, po.code AS doc_code, po.supplier_id AS party_id,
                   po.estimated_total_ccy, po.status AS po_status,
                   po.currency AS doc_ccy, po.fx_rate AS doc_fx,
                   po.approval_status AS po_approval
            INTO v_doc
            FROM purchase_orders po
            WHERE po.id = v_po_id AND po.deleted_at IS NULL;
            IF NOT FOUND THEN
                RAISE EXCEPTION 'ALLOC_INVALID|%', v_po_id;
            END IF;
            IF v_doc.po_status = 'cancelled' THEN
                RAISE EXCEPTION 'ALLOC_INVALID|%', v_doc.doc_code;
            END IF;
            -- APR-2:未获批的采购单不能收预付款
            IF v_doc.po_approval <> 'approved' THEN
                RAISE EXCEPTION 'PO_NOT_APPROVED|%|%', v_doc.doc_code, v_doc.po_approval;
            END IF;
            IF v_doc.party_id IS DISTINCT FROM p_counterparty_id THEN
                RAISE EXCEPTION 'ALLOC_WRONG_PARTY|%', v_doc.doc_code;
            END IF;
            -- ★【WHT-1(A3):预付不在本刀范围内 —— 按名拒,不静默略过】★
            --   它在等的判断更硬:付给非居民顾问的一笔【定金】,本身就是一次
            --   代扣事件 —— 发生在任何发票存在【之前】,而这一刀的债务载体
            --   (expenses)那时还不存在。也就是说这不是"忘了接一根线",
            --   是本刀的裁定(代扣是债务的属性)在这条路上【还没有主语】。
            IF v_payee_residence = 'non_resident' THEN
                RAISE EXCEPTION 'WHT_PREPAYMENT_NOT_SUPPORTED|%', v_doc.doc_code
                  USING HINT = '付给非居民的定金本身就是一次代扣事件,而它发生在任何费用单之前 —— 本刀把代扣挂在债务上,预付那条路还没有债务可挂';
            END IF;
            v_doc_ccy := v_doc.doc_ccy; v_doc_fx := v_doc.doc_fx;
            v_key := v_po_id::text;

            SELECT COALESCE(SUM(pa.allocated_ccy), 0) INTO v_settled
            FROM payment_allocations pa
            JOIN payments p ON p.id = pa.payment_id AND p.status = 'posted'
            WHERE pa.purchase_order_id = v_po_id;

            -- 1.5 倍是【刻意留出的余量】:估算按谈价时的行情算,实际化验和金属价格
            -- 波动都会把真实金额顶高,预付超过估算是正常的;超过一半就不正常了。
            -- 【这条上限【不需要】折算 —— 两边本来就同币种,别再"顺手"加一次】
            -- v_alloc_usd 取自 amount_doc,按定义就是【单据币种】的金额;
            -- v_cap = estimated_total_ccy × 1.5,而 estimated_total_ccy 存的也是
            -- 【单据币种】(create_purchase_order 直接累加行金额,全程不乘汇率;
            -- 名字里的 _usd 是 FIN-1a 留下的旧名,与内容不符,见 docs/known-issues.md)。
            -- 两边同币种 ⇒ 付款是什么币种与这条上限【无关】,fixture 已断言:
            -- 同一张 PO、同一个 amount_doc,SGD 付款与 USD 付款结论完全一致。
            --
            -- 【FIN-16 曾经在这里写过一段相反的注释】,说这一支"需要单独折算"。
            -- 那是错的:代码从未折算,也不该折算,而那段注释举的例子(SGD 8,000 对
            -- USD 6,000 估算)两种算法都放行,根本区分不出有没有折算。
            -- 真正需要折算的是【付款额】那条守卫 ALLOC_EXCEEDS_PAYMENT ——
            -- 见下方 Σ 比较处;跨币种预付会不会超付,由它把关,不由这条上限把关。
            v_cap := round(v_doc.estimated_total_ccy * 1.5, 2);
            v_prior := COALESCE((v_running->>v_key)::numeric, 0);
            IF round(v_settled + v_prior + v_alloc_usd, 2) > v_cap THEN
                RAISE EXCEPTION 'PREPAY_EXCEEDS_ESTIMATE|%|%|%',
                    v_doc.doc_code, round(v_settled + v_prior + v_alloc_usd, 2), v_cap;
            END IF;

            v_po_usd := round(v_po_usd + v_alloc_usd, 2);  -- FIN-2 起为单据币种累计
            v_doc_value := NULL;  -- 无敞口上限,跳过下面的 ALLOC_EXCEEDS

        ELSIF v_batch_id IS NOT NULL THEN
            IF v_sale_id IS NOT NULL OR v_invoice_id IS NOT NULL THEN
                RAISE EXCEPTION 'ALLOC_WRONG_SIDE';
            END IF;
            SELECT ib.id, ib.code AS doc_code, ib.supplier_id AS party_id,
                   ib.unit_price, ib.quantity
            INTO v_doc
            FROM inbound_batches ib
            WHERE ib.id = v_batch_id AND ib.deleted_at IS NULL;
            IF NOT FOUND THEN
                RAISE EXCEPTION 'ALLOC_INVALID|%', v_batch_id;
            END IF;
            IF v_doc.party_id IS DISTINCT FROM p_counterparty_id THEN
                RAISE EXCEPTION 'ALLOC_WRONG_PARTY|%', v_doc.doc_code;
            END IF;
            IF v_doc.unit_price IS NULL THEN
                RAISE EXCEPTION 'ALLOC_UNPRICED|%', v_doc.doc_code;
            END IF;
            -- 应付额永远对着"当前"批次价值(改价即改欠款)
            v_doc_value := round(v_doc.quantity * v_doc.unit_price, 2);
            v_doc_ccy := v_base; v_doc_fx := 1;  -- FIN-0 起批次价值即本位币
            v_birth := v_doc_value;
            v_key := v_batch_id::text;

            -- 已结 = 收付款核销 + 预付冲抵(B6 起,预付冲抵也在还这张单的应付)
            SELECT COALESCE(SUM(pa.allocated_ccy), 0) INTO v_settled
            FROM payment_allocations pa
            JOIN payments p ON p.id = pa.payment_id AND p.status = 'posted'
            WHERE pa.inbound_batch_id = v_batch_id;
            v_settled := v_settled + COALESCE(
                (SELECT SUM(ppa.amount_base) FROM prepayment_applications ppa
                  WHERE ppa.inbound_batch_id = v_batch_id), 0);

        ELSIF v_freight_id IS NOT NULL THEN
            IF v_sale_id IS NOT NULL OR v_invoice_id IS NOT NULL THEN
                RAISE EXCEPTION 'ALLOC_WRONG_SIDE';
            END IF;
            -- ════════════════════════════════════════════════════════════════
            -- PAY-FRT:未付运费单 —— 对手方是【货代】。
            -- 【这一臂逐字照着开支臂写,不是巧合,是判据】两者是同一种单据:
            -- 一张自带币种与入账汇率、贷 2000、挂在一个往来对象名下的应付。
            -- 于是敞口、跨币种结算、已实现汇兑三条全部落在下面【共用】的那段里,
            -- 本臂一行新的 FX 算术都没有 —— 新算术就是第二份算术。
            -- 【筛选条件与 ap_open_items 的运费支逐字一致】unpaid + posted +
            -- 未软删。少一条,画面上能选到的单据与这里能核销的单据就会分家,
            -- 而那正是本刀在关的那种缝。
            -- 【不存在 / 已付 / 已冲销 / 已软删 一律 ALLOC_INVALID】同开支臂:
            -- 四种情况在【调用方能做的事】上没有区别 —— 都是"这张单不能被核销"。
            -- ════════════════════════════════════════════════════════════════
            SELECT fd.id, fd.code AS doc_code, fd.supplier_id AS party_id,
                   fd.amount_ccy AS doc_value, fd.currency AS doc_ccy, fd.fx_rate AS doc_fx,
                   fd.amount_base AS birth_base
            INTO v_doc
            FROM freight_documents fd
            WHERE fd.id = v_freight_id AND fd.payment_status = 'unpaid'
              AND fd.status = 'posted' AND fd.deleted_at IS NULL;
            IF NOT FOUND THEN
                RAISE EXCEPTION 'ALLOC_INVALID|%', v_freight_id;
            END IF;
            IF v_doc.party_id IS DISTINCT FROM p_counterparty_id THEN
                RAISE EXCEPTION 'ALLOC_WRONG_PARTY|%', v_doc.doc_code;
            END IF;
            -- ★【WHT-1(A3):运费不在本刀范围内 —— 按名拒,不静默略过】★
            --   它在等一个【没有人做过】的判断:付给非居民的运费,收款人如果是
            --   船公司/航空公司,是法定豁免的;如果是提供代理服务的货代,未必。
            --   两种情形在 freight_documents 上长得一模一样,而系统分不出来。
            --   静默放过 = 一笔本该代扣的款一分钱都没扣,且看起来完全正常。
            IF v_payee_residence = 'non_resident' THEN
                RAISE EXCEPTION 'WHT_FREIGHT_NOT_SUPPORTED|%', v_doc.doc_code
                  USING HINT = '付给非居民的运费是否代扣,取决于收款人是船公司/航空公司(豁免)还是提供代理服务的货代 —— 这个判断还没有人做过,本刀不猜';
            END IF;
            v_doc_value := v_doc.doc_value;
            v_doc_ccy := v_doc.doc_ccy; v_doc_fx := v_doc.doc_fx;
            v_birth := v_doc.birth_base;
            v_key := v_freight_id::text;

            SELECT COALESCE(SUM(pa.allocated_ccy), 0) INTO v_settled
            FROM payment_allocations pa
            JOIN payments p ON p.id = pa.payment_id AND p.status = 'posted'
            WHERE pa.freight_document_id = v_freight_id;

        ELSE
            IF v_sale_id IS NOT NULL OR v_invoice_id IS NOT NULL THEN
                RAISE EXCEPTION 'ALLOC_WRONG_SIDE';
            END IF;
            -- 挂账开支:必须是 unpaid + posted(不存在/已付/已冲销 → ALLOC_INVALID)
            -- PAYEE-1a:往来对象二选一,所以 party_id 取"那一个"。
            -- CHECK 保证 num_nonnulls(supplier_id, employee_id) = 1,于是 COALESCE
            -- 不会把两个混起来 —— 它挑的是唯一非空的那个。
            -- AP-RECON-1:应付额 = 净额 + 进项税(CLAIM-GST-1 起读落库的 amount_ccy + tax_ccy —— 就是过账的两条贷方腿;
            -- Tim AP-RECON-0 Q1)。只认净额时,一张带税账单的那笔税永远付不进来。
            SELECT e.id, e.code AS doc_code, COALESCE(e.supplier_id, e.employee_id) AS party_id,
                   e.amount_ccy + e.tax_ccy AS doc_value,
                   e.currency AS doc_ccy, e.fx_rate AS doc_fx,
                   -- WHT-1:代扣率来自【债务自己冻下来的那一个】,不在这里重新解析。
                   -- 重新解析 = 第二份实现,而它会在法定税率某天变动之后,
                   -- 让一张旧债务按新税率被代扣 —— 算得出数,没有任何报错。
                   e.wht_rate_pct AS wht_rate_pct,
                   e.amount_base + COALESCE(e.tax_base, 0) AS birth_base
            INTO v_doc
            FROM expenses e
            WHERE e.id = v_expense_id AND e.payment_status = 'unpaid' AND e.status = 'posted';
            IF NOT FOUND THEN
                RAISE EXCEPTION 'ALLOC_INVALID|%', v_expense_id;
            END IF;
            v_wht_rate := v_doc.wht_rate_pct;
            IF v_doc.party_id IS DISTINCT FROM p_counterparty_id THEN
                RAISE EXCEPTION 'ALLOC_WRONG_PARTY|%', v_doc.doc_code;
            END IF;
            v_doc_value := v_doc.doc_value;
            v_doc_ccy := v_doc.doc_ccy; v_doc_fx := v_doc.doc_fx;
            v_birth := v_doc.birth_base;
            v_key := v_expense_id::text;

            SELECT COALESCE(SUM(pa.allocated_ccy), 0) INTO v_settled
            FROM payment_allocations pa
            JOIN payments p ON p.id = pa.payment_id AND p.status = 'posted'
            WHERE pa.expense_id = v_expense_id;
            -- AP-RECON-1(Tim AP-RECON-1 Q4):预付冲抵也在还这张单 —— ap_open_items 与
            -- apply_prepayment 早就这么算,只有这里漏了。漏掉时 EXP-2026-0006
            -- (400,000,已冲定金 120,000)在这里能再付 400,000,而清单上它只欠 280,000。
            -- 进料支(见上)一直是加上的;这里补成同一条。
            v_settled := v_settled + COALESCE(
                (SELECT SUM(ppa.amount_ccy) FROM prepayment_applications ppa
                  WHERE ppa.expense_id = v_expense_id), 0);
        END IF;

        -- ════════════════════════════════════════════════════════════════════
        -- 【FIN-16】核销额是【单据的】金额,以单据币种计 —— 这一条来自 FIN-2,没变,
        -- 也正是它让单据恰好归零。变的是:付款【不必】是同一币种。
        -- 欠 USD 6,000 的客户拿 SGD 付清,这张单就是清了 —— 从前拒绝它不是安全护栏,
        -- 是缺了一个功能(旧 ALLOC_CURRENCY_MISMATCH 已删)。
        -- 本条核销消耗多少付款币种,由【结算日】两个币种的牌价折出来:
        --     消耗 = 单据额 × rate(单据币种) / rate(付款币种)
        -- 同币种时两率相同、比值为 1 —— 老路径逐字节不变,不需要特判。
        -- ════════════════════════════════════════════════════════════════════
        IF v_doc_ccy = p_currency THEN
            v_alloc_pay := v_alloc_usd;
        ELSE
            v_doc_rate := fx_rate_for(v_doc_ccy, v_date,
                            CASE WHEN p_direction = 'in' THEN 'tt_buy' ELSE 'tt_sell' END);
            v_alloc_pay := round(v_alloc_usd * v_doc_rate / v_fx, 2);
        END IF;
        v_alloc_pay_total := v_alloc_pay_total + v_alloc_pay;
        -- ════════════════════════════════════════════════════════════════════
        -- AP-RECON-1 Batch B:解除的本位币 = 清单在这一笔【之前】与【之后】显示的差。
        -- 此前是 round(核销额 × 入账汇率):外币单据部分结清之后,清单(round(剩余 × 汇率))
        -- 与总账差一分,付清时控制科目上留一分(APRECON1-FOREIGN-TAXED-EXPENSE-CENT)。
        -- list_open_base 就是清单的那个式子;逐笔相减,总账为这张单剩下的按构造等于清单。
        -- 本位币单据(汇率 1)两式相同,老路径逐字节不变。预付(v_doc_value 为 NULL)不是
        -- 在解除一笔应付,照旧按付款口径入 1300,见下。
        -- ════════════════════════════════════════════════════════════════════
        IF v_doc_value IS NULL THEN
            v_alloc_base := round(v_alloc_usd * v_doc_fx, 2);
        ELSE
            v_open := round(v_doc_value - v_settled - COALESCE((v_running->>v_key)::numeric, 0), 2);
            v_alloc_base := list_open_base(v_open, v_doc_value, v_birth, v_doc_fx)
                          - list_open_base(round(v_open - v_alloc_usd, 2), v_doc_value, v_birth, v_doc_fx);
        END IF;
        v_base_total := v_base_total + v_alloc_base;
        IF v_po_id IS NOT NULL THEN v_po_base := v_po_base + v_alloc_base; END IF;

        -- ════════════════════════════════════════════════════════════════════
        -- 【WHT-1:代扣多少 —— 按【实际付掉的这一部分】算,不是按债务总额】
        -- 法定义务是"就你付出去的那部分代扣",所以部分结清只扣部分。
        -- 【为什么不按比例摊那张单冻下来的 wht_amount_ccy】按比例摊会在
        -- 多次部分付款之间累积取整误差,最后一次要靠"补齐余额"收口 ——
        -- 而那是一段谁都不敢改的算术。直接乘税率:每一次都精确,而且
        -- 全额付清时 Σ 恰好等于那张单冻下来的预期值(fixture 142 D 臂钉它)。
        IF v_wht_rate IS NOT NULL AND v_wht_rate > 0 THEN
            v_wht_ccy := round(v_alloc_usd * v_wht_rate / 100.0, 2);
            -- 折成付款币种走的是【与这条核销完全相同的那一步】,而不是另写一遍:
            -- 同币种取自身,跨币种用上面刚算出来的 v_doc_rate。
            IF v_doc_ccy = p_currency THEN
                v_wht_pay := v_wht_ccy;
            ELSE
                v_wht_pay := round(v_wht_ccy * v_doc_rate / v_fx, 2);
            END IF;
            v_wht_pay_total := v_wht_pay_total + v_wht_pay;
            -- 【本位币合计由【逐行的那个数】累加,不是最后对合计取一次整】
            -- 两种算法在同币种下相同,跨币种时可以差一分钱 —— 而那一分钱会落在
            -- 「2150 的贷方」与「payment_allocations 各行 withheld_base 之和」之间,
            -- 也就是【表头与它的明细对不上】。本仓库为这件事专门有一份 fixture
            -- (80「一个数字背后的那些行加起来等于那个数字」),所以这里按构造闭合:
            -- 落库的是这一个 v_wht_base,分录贷的是它们的和。
            v_wht_base := round(v_wht_pay * v_fx, 2);
            v_wht_base_total := v_wht_base_total + v_wht_base;
        ELSE
            v_wht_ccy := 0; v_wht_pay := 0; v_wht_base := 0;
        END IF;

        -- 敞口校验(预付除外:v_doc_value 为 NULL)。v_running 让同一目标在同一笔里
        -- 出现两次时,后一条能看见前一条 —— 原实现靠"边插边查"拿到的就是这个语义。
        IF v_doc_value IS NOT NULL THEN
            v_prior := COALESCE((v_running->>v_key)::numeric, 0);
            v_open := round(v_doc_value - v_settled - v_prior, 2);
            IF v_alloc_usd > v_open THEN
                RAISE EXCEPTION 'ALLOC_EXCEEDS|%|%|%', v_doc.doc_code, v_alloc_usd, v_open;
            END IF;
        END IF;

        -- 按单据币种归集,供下面逐币种发行控制科目行
        v_ccy_key := v_doc_ccy;
        IF v_po_id IS NOT NULL THEN
            -- 预付是【非货币性】的,按付款日口径入账 —— 基准额取"消耗掉的付款额 ×
            -- 付款汇率",不是单据入账汇率(同币种时两者相等,老行为不变)。
            v_pre := v_pre || jsonb_build_object(v_ccy_key, jsonb_build_object(
                'ccy',  COALESCE((v_pre->v_ccy_key->>'ccy')::numeric, 0) + v_alloc_usd,
                'base', COALESCE((v_pre->v_ccy_key->>'base')::numeric, 0)
                        + round(v_alloc_pay * v_fx, 2)));
        ELSE
            v_ctrl := v_ctrl || jsonb_build_object(v_ccy_key, jsonb_build_object(
                'ccy',  COALESCE((v_ctrl->v_ccy_key->>'ccy')::numeric, 0) + v_alloc_usd,
                'base', COALESCE((v_ctrl->v_ccy_key->>'base')::numeric, 0) + v_alloc_base));
        END IF;

        v_running := v_running || jsonb_build_object(
            v_key, COALESCE((v_running->>v_key)::numeric, 0) + v_alloc_usd);
        v_valid := v_valid || jsonb_build_array(jsonb_build_object(
            'sales_record_id', v_sale_id, 'inbound_batch_id', v_batch_id,
            'expense_id', v_expense_id, 'purchase_order_id', v_po_id,
            'invoice_id', v_invoice_id, 'freight_document_id', v_freight_id,
            'amount_ccy', v_alloc_usd, 'amount_base', v_alloc_base,
            -- FIN-18:【消耗掉多少付款额】要落库。它是本函数唯一算得出、别处
            -- 再也算不回来的数 —— 见文件头。
            'amount_pay', v_alloc_pay,
            -- WHT-1:其中【没有付出去】的那一部分。allocated_pay 仍然是全额 ——
            -- 供应商的债确实按全额解除了,改它的含义会让 FIN-18 那段注释说谎。
            'withheld_pay', v_wht_pay,
            'withheld_base', v_wht_base));
        v_alloc_total := v_alloc_total + v_alloc_usd;
    END LOOP;

    -- Σ 核销不得超过款额(欠核销 = 挂账余额,允许)
    -- 【与页面同一个毛病的服务端孪生】v_alloc_total 是【单据币种】的合计,
    -- p_amount 是【付款币种】。同币种时看不出来;一旦不同,就是两种货币相减。
    -- 比较必须在付款币种空间做 —— 这正是两切次前在 /finance/payments 上修掉的
    -- 那个 bug,只是长在服务端。
    -- ════════════════════════════════════════════════════════════════════════
    -- ★【WHT-1:这一行【就是】代扣的结构位置,而它此前是不可能的】★
    --   本函数原来的不变量是 Σ核销 ≤ 付款额 —— 也就是【核销永远不能超过现金】。
    --   代扣要的恰恰是超过:结掉 10,000 的债,只付出去 8,500。
    --   于是比较的左边减去代扣额:**真正要与现金比的,是"要付出去的那部分"**。
    --   少了这一句,每一笔带代扣的付款都会撞上 ALLOC_EXCEEDS_PAYMENT,
    --   而错误信息会指向一个完全无辜的地方(看起来像超付)。
    IF round(v_alloc_pay_total - v_wht_pay_total, 2) > p_amount THEN
        RAISE EXCEPTION 'ALLOC_EXCEEDS_PAYMENT|%|%',
            round(v_alloc_pay_total - v_wht_pay_total, 2), p_amount;
    END IF;
    -- 【FIN-3 修订的 C2】已实现汇兑在【结算时点】认列:
    --   控制科目按【单据的】汇率解除(不变);银行按【结算日】口径(牌价/实际);
    --   差额进 7100(已实现)。只要单据汇率和当日汇率,两个数,不追每一块钱的均价。
    -- 未核销部分与预付(非货币,按付款日历史汇率入账)都按当日口径,不产生已实现差异。
    v_bank_base    := round(p_amount * v_fx, 2);
    v_amount_base  := v_bank_base;
    -- 未核销 = 款额 − 【已消耗的付款币种额】。原先减的是 v_alloc_total(单据币种合计)
    -- —— 同币种时相等,不同币种时就是两种货币相减,与 ALLOC_EXCEEDS_PAYMENT 同一个错。
    -- WHT-1:挂账 = 款额 − 【实际付掉的】那部分,而代扣的那部分从来没有付出去。
    -- 不减它,每一笔带代扣的付款都会凭空多出一笔等于代扣额的"挂账余额" ——
    -- 一笔并不存在的、对供应商的预付。
    v_unalloc_ccy  := round(p_amount - (v_alloc_pay_total - v_wht_pay_total), 2);
    v_unalloc_base := round(v_unalloc_ccy * v_fx, 2);
    -- 要汇给 IRAS 的那个数【已经在循环里逐行累加好了】。**按付款当日汇率折本位币**
    -- —— 代扣是今天新产生的一笔负债,不是在解除一笔旧的(与预付 1300 同一条口径);
    -- IRAS 只收新元。这里【不再对合计取一次整】,理由见循环里那段注释:
    -- 那会让 2150 的贷方与各行 withheld_base 之和差一分钱。

    -- ════════════════════════════════════════════════════════════════════════
    -- ★【WHT-1(A4):挂账付款给非居民 —— 【窄】的那一版拒绝】★
    --   一笔挂不上任何单据的出款,系统说不出它是什么性质,于是解析不出税率。
    --   GST 那一侧对【挂账收款】的处置是无条件按名拒
    --   (GST_UNALLOCATED_RECEIPT_UNSUPPORTED),而这里【故意不照抄】——
    --   理由必须写在这里,因为一次没有解释的、与兄弟规矩不同的做法,
    --   在下一个人读起来就是一处疏漏:
    --
    --   **那一条广,是因为在一笔挂账收款上,关于那项供应【什么都不可知】。
    --     这里不同:一个只卖过货的非居民,他的款一分钱都不该代扣 ——
    --     拦下它,是为了一个对他并不成立的理由而拦下一件正当的事。**
    --   而一条会在不适用的情形上开火的拒绝,会教会人绕开它 ——
    --   这个仓库为"学会忽略警报"付过账(hr_alerts.system_start_not_set)。
    --
    --   所以谓词收窄成:非居民 **且** 名下确实有过要代扣的债务。
    --   【残留的缺口,照直写】一个非居民,名下从来没有过要代扣的费用单,
    --   而这笔挂账付款正是给他的一项服务的预付 —— 它会通过。按名记在
    --   docs/known-issues.md,那是选窄版买来的代价,不是没想到。
    IF p_direction = 'out' AND v_unalloc_ccy > 0 AND v_payee_residence = 'non_resident' THEN
        SELECT EXISTS (
            SELECT 1 FROM expenses e
             WHERE e.supplier_id = p_counterparty_id
               AND e.status = 'posted'
               AND e.wht_nature IS NOT NULL
               AND e.wht_nature <> 'none'
        ) INTO v_has_wht_obligation;
        IF v_has_wht_obligation THEN
            RAISE EXCEPTION 'WHT_UNALLOCATED_PAYMENT_UNSUPPORTED|%|%', v_unalloc_ccy, p_currency
              USING HINT = '这个非居民收款人名下有要代扣的债务,而一笔挂账的款说不出它是什么性质、扣多少 —— 先记费用单,再核销到它上面';
        END IF;
    END IF;

    -- ════════════════════════════════════════════════════════════════════════
    -- 【GST-2:"孰早"那条规矩的【另一半】,按名拦住而不是沉默地放过】
    -- 新加坡的供应时点是【开票与收款孰早】。GST-2 实现的是开票那一半;
    -- 收款那一半 —— 一笔【先于任何发票】收到的客户款 —— 同样触发供应,
    -- 而这套系统实现不了它:收款那一刻没有任何东西说得出这笔钱对应哪一项供应,
    -- 于是税码、税率、进哪一格三者都无从解析。
    -- **一条有两半的规矩,不许只做一半就当做完了。** 处置因此是按名拒绝:
    -- 已注册时,一笔挂不上任何单据的客户收款走不下去 —— 先开票,再收款核销。
    -- 【为什么不是"照收,记进 known-issues 就算了"】那样账上会留下一笔
    -- 【已经触发了供应却没有报税】的钱,而它看起来与一笔正常的挂账收款一模一样。
    -- 返回条件写在 docs/known-issues.md。
    IF p_direction = 'in' AND v_unalloc_ccy > 0 AND gst_registered() THEN
        RAISE EXCEPTION 'GST_UNALLOCATED_RECEIPT_UNSUPPORTED|%|%', v_unalloc_ccy, p_currency
          USING HINT = '已注册 GST 时,客户款必须核销到单据上:先开票,再收款';
    END IF;
    -- 预付部分占用的付款额(付款币种)→ 基准。原式 v_po_usd × v_fx 把单据币种的
    -- 数乘了付款汇率,跨币种时不成立;改为按各币种累加出来的基准额直接求和。
    SELECT COALESCE(SUM((value->>'base')::numeric), 0) INTO v_po_pay_base
    FROM jsonb_each(v_pre);
    -- 已实现 = 单据口径解除额 − 当日口径(同币种两率同为 1 ⇒ 恒为 0,不出现 FX 行)
    v_realised := round((v_base_total - v_po_base) - round((v_alloc_total - v_po_usd) * v_fx, 2), 2);

    -- ========================================================================
    -- ② 分录。'out' 且本笔含 PO 预付时【拆两条借方】:
    --      借 1300 预付款项  = 指向 PO 的部分
    --      借 2000 应付账款  = 其余(含未核销部分 —— 与改动前对全额借 2000 一致)
    --      贷 银行          = 全额
    --    金额:核销额是 USD,分录行按原币记,故 po_ccy = round(po_usd / fx, 2),
    --    ap_ccy = p_amount − po_ccy(【相减而非各自取整】,保证两条借方的原币恰好
    --    合计等于贷方)。USD 侧由 post_journal_entry 用 round(ccy × fx, 2) 反算,
    --    非本位币下双重取整可能差 1 分,故下面在 ±0.02 内挑一个能让 USD 恰好配平的
    --    拆分点(USD 付款 fx=1,偏移恒为 0)。
    -- ========================================================================
    v_code := fin_next_payment_code(CASE WHEN p_direction = 'in' THEN document_type_prefix('payment_receipt') ELSE document_type_prefix('payment_out') END, v_date);

    -- 行 fx = 目标基准额 ÷ 原币额(除后反乘取整恰好还原);0 金额行一律不发。
    v_lines := '[]'::jsonb;
    IF p_direction = 'in' THEN
        v_lines := v_lines || jsonb_build_object('account_code', v_bank, 'side', 'debit',
            'currency', p_currency, 'amount_ccy', p_amount, 'fx_rate', v_bank_base / p_amount);
        -- 【逐单据币种】解除应收:金额是单据的原币,汇率是单据的入账汇率。
        -- 原先这里写死 p_currency —— 同币种时看不出来,两种币种时标签就是错的。
        FOR v_grp IN SELECT key AS ccy, (value->>'ccy')::numeric AS ccy_amt,
                            (value->>'base')::numeric AS base_amt
                     FROM jsonb_each(v_ctrl) ORDER BY key
        LOOP
            IF v_grp.ccy_amt > 0 THEN
                v_lines := v_lines || jsonb_build_object('account_code', '1100', 'side', 'credit',
                    'currency', v_grp.ccy, 'amount_ccy', v_grp.ccy_amt,
                    'fx_rate', v_grp.base_amt / v_grp.ccy_amt,
                    'line_memo', 'settled at document rate');
            END IF;
        END LOOP;
        IF v_unalloc_ccy > 0 THEN
            v_lines := v_lines || jsonb_build_object('account_code', '1100', 'side', 'credit',
                'currency', p_currency, 'amount_ccy', v_unalloc_ccy, 'fx_rate', v_unalloc_base / v_unalloc_ccy);
        END IF;
        -- 已实现差额:贷方合计 − 银行借方。>0 = 损(补借 7100),<0 = 益(补贷 7100)
        v_realised := round(COALESCE(v_base_total, 0) + v_unalloc_base - v_bank_base, 2);
        IF v_realised > 0 THEN
            v_lines := v_lines || jsonb_build_object('account_code', '7100', 'side', 'debit',
                'currency', base_currency_code(), 'amount_ccy', v_realised);
        ELSIF v_realised < 0 THEN
            v_lines := v_lines || jsonb_build_object('account_code', '7100', 'side', 'credit',
                'currency', base_currency_code(), 'amount_ccy', -v_realised);
        END IF;
    ELSE
        FOR v_grp IN SELECT key AS ccy, (value->>'ccy')::numeric AS ccy_amt,
                            (value->>'base')::numeric AS base_amt
                     FROM jsonb_each(v_ctrl) ORDER BY key
        LOOP
            IF v_grp.ccy_amt > 0 THEN
                v_lines := v_lines || jsonb_build_object('account_code', '2000', 'side', 'debit',
                    'currency', v_grp.ccy, 'amount_ccy', v_grp.ccy_amt,
                    'fx_rate', v_grp.base_amt / v_grp.ccy_amt,
                    'line_memo', 'settled at document rate');
            END IF;
        END LOOP;
        IF v_unalloc_ccy > 0 THEN
            v_lines := v_lines || jsonb_build_object('account_code', '2000', 'side', 'debit',
                'currency', p_currency, 'amount_ccy', v_unalloc_ccy, 'fx_rate', v_unalloc_base / v_unalloc_ccy);
        END IF;
        FOR v_grp IN SELECT key AS ccy, (value->>'ccy')::numeric AS ccy_amt,
                            (value->>'base')::numeric AS base_amt
                     FROM jsonb_each(v_pre) ORDER BY key
        LOOP
            IF v_grp.ccy_amt > 0 THEN
                v_lines := v_lines || jsonb_build_object('account_code', '1300', 'side', 'debit',
                    'currency', v_grp.ccy, 'amount_ccy', v_grp.ccy_amt,
                    'fx_rate', v_grp.base_amt / v_grp.ccy_amt,
                    'line_memo', 'Prepayment');
            END IF;
        END LOOP;
        -- ════════════════════════════════════════════════════════════════════
        -- ★【WHT-1:代扣的那一笔 —— 债全额解除,钱只走净额】★
        --   借方(2000)已经是【全额】,银行贷方是【净额】(调用方递进来的
        --   p_amount 就是实际离开银行的钱),差额在这里贷 2150。
        --   **这就是 3.2 说的"代扣不是折扣"落成分录的样子**:供应商那张单
        --   闭合到零,而银行只动了净额,中间那一笔成为对 IRAS 的负债。
        --   【本位币记账,不带原币敞口】IRAS 只收新元,代扣额在付款那一刻
        --   就固定成一个新元数字 —— 它此后不再随汇率变动,所以这条腿走
        --   base_currency_code(),与 7100 那两条同一种写法。
        IF v_wht_base_total > 0 THEN
            v_lines := v_lines || jsonb_build_object('account_code', '2150', 'side', 'credit',
                'currency', base_currency_code(), 'amount_ccy', v_wht_base_total,
                'line_memo', 'Withholding tax on ' || v_code);
        END IF;
        v_lines := v_lines || jsonb_build_object('account_code', v_bank, 'side', 'credit',
            'currency', p_currency, 'amount_ccy', p_amount, 'fx_rate', v_bank_base / p_amount);
        -- 借方合计 − 银行贷方:>0 说明按旧率解除得多 → 贷 7100(益);<0 → 借 7100(损)
        -- 【减去代扣额】它是一条【新增的贷方】,不减就会被整个算进已实现汇兑,
        -- 把一笔代扣伪装成一笔汇兑损失 —— 而分录仍然是平的,不会有任何报错。
        v_realised := round((v_base_total - v_po_base) + v_unalloc_base + v_po_pay_base
                            - v_bank_base - v_wht_base_total, 2);
        IF v_realised > 0 THEN
            v_lines := v_lines || jsonb_build_object('account_code', '7100', 'side', 'credit',
                'currency', base_currency_code(), 'amount_ccy', v_realised);
        ELSIF v_realised < 0 THEN
            v_lines := v_lines || jsonb_build_object('account_code', '7100', 'side', 'debit',
                'currency', base_currency_code(), 'amount_ccy', -v_realised);
        END IF;
    END IF;

    v_je := post_journal_entry(
        v_date,
        CASE WHEN p_direction = 'in' THEN 'Receipt ' ELSE 'Payment ' END || v_code,
        'payment', v_payment_id, v_lines);

    -- ③ 插入收付款单(带着分录链接一次到位;不可变表无后续 UPDATE)
    INSERT INTO payments (id, code, direction, counterparty_type, customer_id, supplier_id,
                          employee_id,
                          amount_ccy, currency, fx_rate, amount_base, bank_account_code,
                          payment_date, notes, journal_entry_id, created_by)
    VALUES (v_payment_id, v_code, p_direction,
            v_kind,
            CASE WHEN v_kind = 'customer' THEN p_counterparty_id END,
            CASE WHEN v_kind = 'supplier' THEN p_counterparty_id END,
            CASE WHEN v_kind = 'employee' THEN p_counterparty_id END,
            p_amount, p_currency, v_fx, v_amount_base, v_bank,
            v_date, p_notes, (v_je->>'entry_id')::uuid, v_user);

    -- ④ 核销行落库(①已全部校验过,这里只写)
    FOR v_alloc IN SELECT * FROM jsonb_array_elements(v_valid)
    LOOP
        INSERT INTO payment_allocations (payment_id, sales_record_id, inbound_batch_id,
                                         expense_id, purchase_order_id, invoice_id,
                                         freight_document_id,
                                         allocated_ccy, allocated_base, allocated_pay,
                                         withheld_pay, withheld_base)
        VALUES (v_payment_id,
                (v_alloc->>'sales_record_id')::uuid,
                (v_alloc->>'inbound_batch_id')::uuid,
                (v_alloc->>'expense_id')::uuid,
                (v_alloc->>'purchase_order_id')::uuid,
                (v_alloc->>'invoice_id')::uuid,
                (v_alloc->>'freight_document_id')::uuid,
                (v_alloc->>'amount_ccy')::numeric,
                (v_alloc->>'amount_base')::numeric,
                (v_alloc->>'amount_pay')::numeric,
                (v_alloc->>'withheld_pay')::numeric,
                (v_alloc->>'withheld_base')::numeric);
    END LOOP;

    -- ════════════════════════════════════════════════════════════════════════
    -- 【FIN-18】返回值里原有 allocated_total = v_alloc_total 与
    -- unallocated = p_amount - v_alloc_total。函数体早已把分录与
    -- ALLOC_EXCEEDS_PAYMENT 都改到 v_alloc_pay_total(付款币种),【只有返回值
    -- 留在原地】:v_alloc_total 是各单据币种核销额的直接相加 —— 一张 USD 单
    -- 加一张 SGD 单;拿它去减付款币种的 p_amount 更是两种货币相减。
    -- 今天没有调用方读它(action 只取 payment_id),所以它不是 bug,是给下一个
    -- 调用方埋的坑。带单位的换上,没单位的撤掉。
    -- ════════════════════════════════════════════════════════════════════════
    RETURN jsonb_build_object(
        'payment_id', v_payment_id,
        'code', v_code,
        'currency', p_currency,                       -- 下面两个数的单位
        'amount_base', v_amount_base,
        'journal_code', v_je->>'code',
        'allocated_pay_total', round(v_alloc_pay_total, 2),  -- 付款币种:消耗掉的款额
        'unallocated', v_unalloc_ccy,                        -- 付款币种:挂账余额
        -- WHT-1:代扣了多少。**两个数分开报,而且各自带单位** ——
        -- withheld_pay 是现金算术里的那个数(付款币种),
        -- withheld_base 是【要汇给 IRAS 的那个数】(本位币)。
        -- 合成一个会重蹈 FIN-18 那个坑:一个没有单位的数,给下一个调用方埋雷。
        'withheld_pay_total', round(v_wht_pay_total, 2),
        'withheld_base_total', v_wht_base_total,
        -- 单据币种的核销额【按币种分开列】,不求和
        'settled_by_ccy', (SELECT COALESCE(jsonb_object_agg(key, value->'ccy'), '{}'::jsonb)
                             FROM jsonb_each(v_ctrl)),
        'prepaid_by_ccy', (SELECT COALESCE(jsonb_object_agg(key, value->'ccy'), '{}'::jsonb)
                             FROM jsonb_each(v_pre))
    );
END;
$function$
;

-- ═══ db/functions/apply_prepayment.sql ═══
CREATE OR REPLACE FUNCTION public.apply_prepayment(p_purchase_order_id uuid, p_inbound_batch_id uuid, p_amount numeric, p_notes text DEFAULT NULL::text, p_expense_id uuid DEFAULT NULL::uuid, p_release_date date DEFAULT NULL::date)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_user        uuid := auth.uid();
    v_base        text := base_currency_code();
    v_po          record;
    v_batch       record;
    v_exp         record;
    v_prepaid     numeric;   -- Σ 已付到该单的预付,本位币
    v_prepaid_ccy numeric;   -- Σ 同上,按【采购单币种】
    v_applied     numeric;   -- Σ 已冲抵,本位币
    v_available   numeric;
    v_dep_ccy     text;      -- 定金的币种 = 采购单的币种
    v_dep_rate    numeric;   -- 定金的加权平均汇率
    v_pay_ccy     text;      -- 被解除应付的计价币种
    v_pay_rate    numeric;   -- 被解除应付的【入账】汇率
    v_value       numeric;
    v_settled     numeric;
    v_open        numeric;
    v_dep_ccy_amt numeric;   -- 本次消耗的定金,按定金币种
    v_dep_base    numeric;   -- 本次消耗的定金,本位币(= 落库的 amount_base)
    v_pay_base    numeric;   -- 本次解除的应付,本位币
    v_realised    numeric;
    v_dest_code   text;      -- 目的地单据的编号(分录摘要用)
    v_lines       jsonb;
    v_app_id      uuid := gen_random_uuid();
    v_je          jsonb;
BEGIN
    PERFORM require_permission('module.finance.edit');

    -- ════════════════════════════════════════════════════════════════════════
    -- EQP-1c-b(X1):冲抵日【必填,永不默认】。
    -- 【它决定一个期间】这笔分录借 2000 / 贷 1300,过在哪一天就落在哪个月。
    -- 此前它是 CURRENT_DATE,而 AGENTS.md 那条规矩点名的正是这种默认:
    -- 今天的日期【永远撞不上 PERIOD_LOCKED】,于是"把日期留空"变成一条
    -- 比"填对一个已关期间的日期"更顺的路 —— 这条路奖励留空。
    -- 【为什么用"带默认值 + 按名拒",而不是让它位置上必填】FIN-10 那十一个函数
    -- 立的先例:老调用方少传一个参数时,应当拿到一句【人话】,而不是
    -- "function does not exist"。破窗期间生产跑的是旧代码,它就落在这一句上。
    IF p_release_date IS NULL THEN
        RAISE EXCEPTION 'RELEASE_DATE_REQUIRED';
    END IF;

    -- 目的地【恰好一个】。表上那条 CHECK 是兜底(直插也逃不掉);这里按名拒绝,
    -- 因为本仓库的规矩是"拒绝要有名字,屏幕上不出现裸的约束违例"。
    IF num_nonnulls(p_inbound_batch_id, p_expense_id) <> 1 THEN
        RAISE EXCEPTION 'PREPAY_DESTINATION_INVALID|%',
            num_nonnulls(p_inbound_batch_id, p_expense_id)
          USING HINT = '一次冲抵恰好冲一个目的地:一张进料批次,或一张费用单';
    END IF;

    SELECT po.id, po.code, po.supplier_id, po.status, po.approval_status, po.currency
    INTO v_po
    FROM purchase_orders po
    WHERE po.id = p_purchase_order_id AND po.deleted_at IS NULL;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'PO_NOT_FOUND|%', COALESCE(p_purchase_order_id::text, '?');
    END IF;
    IF v_po.status = 'cancelled' THEN
        RAISE EXCEPTION 'PO_CANCELLED|%', v_po.code;
    END IF;
    -- APR-2:未获批的采购单不能动钱
    IF v_po.approval_status <> 'approved' THEN
        RAISE EXCEPTION 'PO_NOT_APPROVED|%|%', v_po.code, v_po.approval_status;
    END IF;
    IF p_amount IS NULL OR p_amount <= 0 THEN
        RAISE EXCEPTION 'AMOUNT_INVALID';
    END IF;

    -- ════════════════════════════════════════════════════════════════════════
    -- 定金那一侧。
    -- 【币种】1300 由 record_payment 按【单据(= 采购单)币种】归集(FIN-16 的
    -- v_pre 逐币种发行控制科目行),所以定金的币种就是采购单的币种。
    -- 【汇率】复用 FIN-16 已经记下来的结果,不重算:
    --     加权平均 = Σ allocated_base / Σ allocated_ccy
    -- ════════════════════════════════════════════════════════════════════════
    v_dep_ccy := v_po.currency;

    SELECT COALESCE(SUM(pa.allocated_base), 0), COALESCE(SUM(pa.allocated_ccy), 0)
    INTO v_prepaid, v_prepaid_ccy
    FROM payment_allocations pa
    JOIN payments p ON p.id = pa.payment_id AND p.status = 'posted'
    WHERE pa.purchase_order_id = p_purchase_order_id;

    -- ════════════════════════════════════════════════════════════════════════
    -- 【可用预付这条守卫留在本位币空间 —— 这是刻意的,不要"顺手"改成币种空间】
    -- amount_ccy 在那一条 2026-07-31 的历史行上是 NULL(FIN-0 翻转之前记的,
    -- 刻意不回填)。一旦改成 Σ amount_ccy,那一行会被【静默跳过】,于是
    -- PO-2026-0001 上一笔【已经全额冲抵完】的 30,000 定金会读成"还有 30,000 可用",
    -- 冲第二次而没有任何东西反对。amount_base 在那一行上是有值的,所以本位币
    -- 空间数得对。币种是【记下来、过账用】的,不用来决定还剩多少。
    -- fixture 103b 的 H 臂把这一条钉死了。
    -- ════════════════════════════════════════════════════════════════════════
    SELECT COALESCE(SUM(ppa.amount_base), 0) INTO v_applied
    FROM prepayment_applications ppa
    WHERE ppa.purchase_order_id = p_purchase_order_id;

    v_available := round(v_prepaid - v_applied, 2);
    IF v_prepaid_ccy > 0 THEN
        v_dep_rate := v_prepaid / v_prepaid_ccy;
    END IF;
    IF v_dep_rate IS NULL OR v_dep_rate <= 0 THEN
        RAISE EXCEPTION 'PREPAY_INSUFFICIENT|%|%', 0, p_amount;
    END IF;

    -- ── 目的地:两种单据,各自解出【计价币种】、【入账汇率】与【敞口】───────
    IF p_inbound_batch_id IS NOT NULL THEN
        SELECT ib.id, ib.code, ib.supplier_id, ib.quantity, ib.unit_price
        INTO v_batch
        FROM inbound_batches ib
        WHERE ib.id = p_inbound_batch_id AND ib.deleted_at IS NULL;
        IF NOT FOUND THEN
            RAISE EXCEPTION 'INBOUND_NOT_FOUND|%', COALESCE(p_inbound_batch_id::text, '?');
        END IF;
        IF v_batch.unit_price IS NULL THEN
            RAISE EXCEPTION 'INBOUND_UNPRICED|%', v_batch.code;
        END IF;
        IF v_batch.supplier_id IS DISTINCT FROM v_po.supplier_id THEN
            RAISE EXCEPTION 'SUPPLIER_MISMATCH|%|%', v_po.code, v_batch.code;
        END IF;

        -- 【进料应付恒以本位币计价】reprice_inbound_batch(set_inbound_unit_price
        -- 只是它的转发)按 base_currency_code() 过账 2000,ap_open_items 的进料支
        -- 也把 currency 取成 currencies.is_base。线上 9 条 source_type='purchase'
        -- 的 2000 行,fx_rate 无一例外是 1 —— 即当日的本位币。
        v_pay_ccy  := v_base;
        v_pay_rate := 1;

        v_value := round(v_batch.quantity * v_batch.unit_price, 2);
        SELECT COALESCE(SUM(pa.allocated_base), 0) INTO v_settled
        FROM payment_allocations pa
        JOIN payments p ON p.id = pa.payment_id AND p.status = 'posted'
        WHERE pa.inbound_batch_id = p_inbound_batch_id;
        v_settled := v_settled + COALESCE(
            (SELECT SUM(ppa.amount_base) FROM prepayment_applications ppa
              WHERE ppa.inbound_batch_id = p_inbound_batch_id), 0);
        v_open := round(v_value - v_settled, 2);
        v_dest_code := v_batch.code;
    ELSE
        SELECT e.id, e.code, e.currency, e.fx_rate, e.amount_ccy, e.tax_rate_pct, e.tax_ccy,
               e.supplier_id, e.status, e.payment_status
        INTO v_exp
        FROM expenses e WHERE e.id = p_expense_id;
        IF NOT FOUND THEN
            RAISE EXCEPTION 'EXPENSE_NOT_FOUND|%', COALESCE(p_expense_id::text, '?');
        END IF;
        IF v_exp.status <> 'posted' THEN
            RAISE EXCEPTION 'EXPENSE_NOT_POSTED|%|%', v_exp.code, v_exp.status;
        END IF;
        -- 已付的费用单没有应付可解除 —— 那笔钱当时就走了银行。
        IF v_exp.payment_status <> 'unpaid' THEN
            RAISE EXCEPTION 'EXPENSE_NOT_PAYABLE|%', v_exp.code
              USING HINT = '只有挂账(unpaid)的费用单才有应付可以让定金去冲';
        END IF;
        -- 冲销镜像单只是记录凭证,不是新的应付单据(ap_open_items 也把它排除)。
        IF EXISTS (SELECT 1 FROM expenses o WHERE o.reversed_by_expense = v_exp.id) THEN
            RAISE EXCEPTION 'EXPENSE_IS_REVERSAL_MIRROR|%', v_exp.code;
        END IF;
        IF v_exp.supplier_id IS DISTINCT FROM v_po.supplier_id THEN
            RAISE EXCEPTION 'SUPPLIER_MISMATCH|%|%', v_po.code, v_exp.code;
        END IF;

        -- 费用单的应付以【单据自己的币种】计价(record_expense 按 p_currency 贷 2000),
        -- 入账汇率就是单据上冻住的那一个。敞口因此在单据币种空间递减 ——
        -- 与 ap_open_items 的费用支同一个口径。
        v_pay_ccy  := v_exp.currency;
        v_pay_rate := v_exp.fx_rate;

        SELECT COALESCE(SUM(pa.allocated_ccy), 0) INTO v_settled
        FROM payment_allocations pa
        JOIN payments p ON p.id = pa.payment_id AND p.status = 'posted'
        WHERE pa.expense_id = p_expense_id;
        v_settled := v_settled + COALESCE(
            (SELECT SUM(ppa.amount_ccy) FROM prepayment_applications ppa
              WHERE ppa.expense_id = p_expense_id), 0);
        -- AP-RECON-1:应付额是【净额 + 进项税】(CLAIM-GST-1 起读落库的 amount_ccy + tax_ccy)——
        -- 只认净额的上限会让定金冲不掉那张单上的税,而那一笔税就挂在 2000 上没人能动。
        v_open := round(v_exp.amount_ccy + v_exp.tax_ccy - v_settled, 2);
        v_dest_code := v_exp.code;
    END IF;

    -- p_amount 以【被解除应付的币种】陈述(进料支即本位币,与本刀之前逐字一致)
    IF p_amount > v_open THEN
        RAISE EXCEPTION 'EXCEEDS_OPEN|%|%', v_open, p_amount;
    END IF;

    -- ════════════════════════════════════════════════════════════════════════
    -- R1 / R2 / R3 —— 判据是【定金币种】与【应付币种】的关系。
    -- 两条支路都【不读任何当日牌价】:两条腿都是历史入账,没有钱在动,
    -- 也就没有一次兑换需要定价。
    -- ════════════════════════════════════════════════════════════════════════
    IF v_pay_ccy = v_dep_ccy THEN
        -- R1 单位对齐:付了 10,000 USD、欠 50,000 USD 的人,现在欠 40,000 USD。
        -- 已实现汇兑 = 同样这 A 个单位,按应付的入账汇率与按定金的加权汇率,
        -- 两个【历史】本位币值之差。
        v_dep_ccy_amt := p_amount;
        v_dep_base    := round(p_amount * v_dep_rate, 2);
        v_pay_base    := round(p_amount * v_pay_rate, 2);
    ELSIF v_pay_ccy = v_base OR v_dep_ccy = v_base THEN
        -- R2 价值对齐:两者恰有一个是本位币。按定金【自己的】汇率折出等值的
        -- 定金数量,于是两侧本位币值恒等,7100 恒为零。
        -- 【那个零是构造出来的,不是漏算的】1300 是 is_monetary = false:预付按
        -- 付款那天的汇率计量,此后永不重译。按它自己的汇率消耗它,不可能产生损益。
        v_pay_base    := round(p_amount * v_pay_rate, 2);
        v_dep_base    := v_pay_base;
        v_dep_ccy_amt := round(v_pay_base / v_dep_rate, 2);
    ELSE
        -- R3 两边都是外币且不同 —— 这才需要一次真正的换算,而这盘生意里它不存在。
        RAISE EXCEPTION 'PREPAY_TWO_FOREIGN_CURRENCIES|%|%', v_dep_ccy, v_pay_ccy
          USING HINT = '定金与应付是两种不同的外币 —— 请让其中一方以本位币开票';
    END IF;

    IF v_dep_ccy_amt IS NULL OR v_dep_ccy_amt <= 0 THEN
        RAISE EXCEPTION 'AMOUNT_INVALID';
    END IF;
    IF v_dep_base > v_available THEN
        RAISE EXCEPTION 'PREPAY_INSUFFICIENT|%|%', v_available, v_dep_base;
    END IF;

    v_realised := round(v_pay_base - v_dep_base, 2);

    -- 分录:钱早就出去了,这里只是科目之间的搬运。
    -- 【汇率逐行给成 base/ccy 的商】与 record_payment 同一个手法 —— 这样
    -- post_journal_entry 折出来的本位币值与上面算的逐分相等,分录不会因为
    -- 一次四舍五入而不平,R2 的"恒为零"也才真的是零。
    v_lines := jsonb_build_array(
        jsonb_build_object('account_code', '2000', 'side', 'debit',
                           'currency', v_pay_ccy, 'amount_ccy', p_amount,
                           'fx_rate', v_pay_base / p_amount),
        jsonb_build_object('account_code', '1300', 'side', 'credit',
                           'currency', v_dep_ccy, 'amount_ccy', v_dep_ccy_amt,
                           'fx_rate', v_dep_base / v_dep_ccy_amt,
                           'line_memo', 'Prepayment applied'));
    -- 借方合计 − 贷方合计:>0 说明按旧率解除得多 → 贷 7100(益);<0 → 借 7100(损)。
    -- 与 record_payment 的方向约定逐字一致。
    IF v_realised > 0 THEN
        v_lines := v_lines || jsonb_build_object('account_code', '7100', 'side', 'credit',
            'currency', v_base, 'amount_ccy', v_realised, 'fx_rate', 1);
    ELSIF v_realised < 0 THEN
        v_lines := v_lines || jsonb_build_object('account_code', '7100', 'side', 'debit',
            'currency', v_base, 'amount_ccy', -v_realised, 'fx_rate', 1);
    END IF;

    v_je := post_journal_entry(
        p_release_date,
        -- 【不要写 COALESCE(v_batch.code, v_exp.code)】没走到的那一支里,那个
        -- record 变量【从未被赋值】,读它的字段是一个错误(record ... is not
        -- assigned yet),不是 NULL —— COALESCE 救不了。实测撞过。
        'Prepayment applied ' || v_po.code || ' → ' || v_dest_code,
        'prepayment', v_app_id, v_lines);

    INSERT INTO prepayment_applications (id, purchase_order_id, inbound_batch_id, expense_id,
                                         amount_base, currency, amount_ccy,
                                         notes, journal_entry_id, created_by)
    VALUES (v_app_id, p_purchase_order_id, p_inbound_batch_id, p_expense_id,
            v_dep_base, v_pay_ccy, p_amount,
            p_notes, (v_je->>'entry_id')::uuid, v_user);

    RETURN jsonb_build_object(
        'application_id', v_app_id,
        'purchase_order_id', p_purchase_order_id,
        'inbound_batch_id', p_inbound_batch_id,
        'expense_id', p_expense_id,
        'currency', v_pay_ccy,
        'amount_ccy', p_amount,
        'amount_base', v_dep_base,
        'deposit_currency', v_dep_ccy,
        'deposit_amount_ccy', v_dep_ccy_amt,
        'deposit_rate', v_dep_rate,
        'realised_fx', v_realised,
        'journal_code', v_je->>'code',
        'prepaid_remaining', round(v_available - v_dep_base, 2)
    );
END;
$function$;

-- ═══ db/views/ap_open_items.sql ═══
CREATE OR REPLACE VIEW public.ap_open_items WITH (security_invoker = off) AS
 SELECT doc_kind,
    doc_id,
    doc_code,
    inbound_batch_id,
    supplier_id,
    supplier_name,
    doc_date,
    doc_value_base,
    settled_base,
    open_base,
    currency,
    open_ccy,
    CURRENT_DATE - doc_date AS days_outstanding,
    aging_bucket(CURRENT_DATE - doc_date) AS bucket,
    counterparty_kind,
    counterparty_id,
    counterparty_name
   FROM ( SELECT 'inbound'::text AS doc_kind,
            ib.id AS doc_id,
            ib.code AS doc_code,
            ib.id AS inbound_batch_id,
            ib.supplier_id,
            sup.legal_name AS supplier_name,
            COALESCE(ib.arrival_date, ib.created_at::date) AS doc_date,
            round(ib.quantity * ib.unit_price, 2) AS doc_value_base,
            round(COALESCE(s.settled, 0::numeric) + COALESCE(pp.applied, 0::numeric), 2) AS settled_base,
            round(round(ib.quantity * ib.unit_price, 2) - COALESCE(s.settled, 0::numeric) - COALESCE(pp.applied, 0::numeric), 2) AS open_base,
            ( SELECT c.code
                   FROM currencies c
                  WHERE c.is_base) AS currency,
            round(round(ib.quantity * ib.unit_price, 2) - COALESCE(s.settled, 0::numeric) - COALESCE(pp.applied, 0::numeric), 2) AS open_ccy,
            'supplier'::text AS counterparty_kind,
            ib.supplier_id AS counterparty_id,
            sup.legal_name AS counterparty_name
           FROM inbound_batches_masked ib
             JOIN suppliers sup ON sup.id = ib.supplier_id
             LEFT JOIN LATERAL ( SELECT sum(pa.allocated_ccy) AS settled
                   FROM payment_allocations pa
                     JOIN payments p ON p.id = pa.payment_id AND p.status = 'posted'::text
                  WHERE pa.inbound_batch_id = ib.id) s ON true
             LEFT JOIN LATERAL ( SELECT sum(ppa.amount_base) AS applied
                   FROM prepayment_applications_masked ppa
                  WHERE ppa.inbound_batch_id = ib.id) pp ON true
          WHERE ib.deleted_at IS NULL AND ib.unit_price IS NOT NULL
        UNION ALL
         SELECT 'expense'::text AS doc_kind,
            e.id AS doc_id,
            e.code AS doc_code,
            NULL::uuid AS inbound_batch_id,
            e.supplier_id,
            sup.legal_name AS supplier_name,
            e.expense_date AS doc_date,
            e.amount_base + COALESCE(e.tax_base, 0::numeric) AS doc_value_base,
            round((COALESCE(s.settled, 0::numeric) + COALESCE(pp.applied, 0::numeric)) * e.fx_rate, 2) AS settled_base,
                CASE
                    WHEN (COALESCE(s.settled, 0::numeric) + COALESCE(pp.applied, 0::numeric)) = 0::numeric THEN e.amount_base + COALESCE(e.tax_base, 0::numeric)
                    ELSE round((e.amount_ccy + e.tax_ccy - COALESCE(s.settled, 0::numeric) - COALESCE(pp.applied, 0::numeric)) * e.fx_rate, 2)
                END AS open_base,
            e.currency,
            round(e.amount_ccy + e.tax_ccy - COALESCE(s.settled, 0::numeric) - COALESCE(pp.applied, 0::numeric), 2) AS open_ccy,
                CASE
                    WHEN e.employee_id IS NOT NULL THEN 'employee'::text
                    ELSE 'supplier'::text
                END AS counterparty_kind,
            COALESCE(e.supplier_id, e.employee_id) AS counterparty_id,
            COALESCE(sup.legal_name, emp.legal_name) AS counterparty_name
           FROM expenses e
             LEFT JOIN suppliers sup ON sup.id = e.supplier_id
             LEFT JOIN employees emp ON emp.id = e.employee_id
             LEFT JOIN LATERAL ( SELECT sum(pa.allocated_ccy) AS settled
                   FROM payment_allocations pa
                     JOIN payments p ON p.id = pa.payment_id AND p.status = 'posted'::text
                  WHERE pa.expense_id = e.id) s ON true
             LEFT JOIN LATERAL ( SELECT sum(ppa.amount_ccy) AS applied
                   FROM prepayment_applications_masked ppa
                  WHERE ppa.expense_id = e.id) pp ON true
          WHERE e.payment_status = 'unpaid'::text AND e.status = 'posted'::text AND NOT (EXISTS ( SELECT 1
                   FROM expenses o
                  WHERE o.reversed_by_expense = e.id))
        UNION ALL
         SELECT 'freight'::text AS doc_kind,
            fd.id AS doc_id,
            fd.code AS doc_code,
            NULL::uuid AS inbound_batch_id,
            fd.supplier_id,
            sup.legal_name AS supplier_name,
            fd.doc_date,
            fd.amount_base AS doc_value_base,
            round(COALESCE(s.settled, 0::numeric) * fd.fx_rate, 2) AS settled_base,
            round((fd.amount_ccy - COALESCE(s.settled, 0::numeric)) * fd.fx_rate, 2) AS open_base,
            fd.currency,
            round(fd.amount_ccy - COALESCE(s.settled, 0::numeric), 2) AS open_ccy,
            'supplier'::text AS counterparty_kind,
            fd.supplier_id AS counterparty_id,
            sup.legal_name AS counterparty_name
           FROM freight_documents fd
             JOIN suppliers sup ON sup.id = fd.supplier_id
             LEFT JOIN LATERAL ( SELECT sum(pa.allocated_ccy) AS settled
                   FROM payment_allocations pa
                     JOIN payments p ON p.id = pa.payment_id AND p.status = 'posted'::text
                  WHERE pa.freight_document_id = fd.id) s ON true
          WHERE fd.payment_status = 'unpaid'::text AND fd.status = 'posted'::text AND fd.deleted_at IS NULL) d
  WHERE open_ccy > 0::numeric AND has_permission('module.finance.view'::text);

-- ═══ db/views/expense_claim_status.sql ═══
CREATE OR REPLACE VIEW public.expense_claim_status WITH (security_invoker = off) AS
SELECT c.id AS claim_id,
    c.code,
    c.employee_id,
    e.code AS employee_code,
    e.legal_name AS employee_name,
    c.spend_date,
    c.submitted_at,
    c.amount_ccy,
    c.currency,
    c.description,
    c.no_receipt_reason,
    c.status,
    c.decided_at,
    c.decision_notes,
    c.account_code,
    c.tax_code,
    c.posting_date,
    c.expense_id,
    x.payment_status,
    x.status = 'reversed'::text AS expense_reversed,
    COALESCE(a.settled_ccy, 0::numeric) AS settled_ccy,
    c.status = 'approved'::text AND x.status = 'posted'::text AND COALESCE(a.settled_ccy, 0::numeric) >= (x.amount_ccy + x.tax_ccy) AS is_paid,
    c.status = 'approved'::text AND x.status = 'posted'::text AND COALESCE(a.settled_ccy, 0::numeric) < (x.amount_ccy + x.tax_ccy) AS is_owing,
    (EXISTS ( SELECT 1
           FROM finance_attachments fa
          WHERE fa.claim_id = c.id AND fa.deleted_at IS NULL)) AS has_receipt,
    x.amount_ccy AS expense_net_ccy,
    x.tax_ccy AS expense_tax_ccy
   FROM expense_claims c
     JOIN employees e ON e.id = c.employee_id
     LEFT JOIN expenses x ON x.id = c.expense_id
     LEFT JOIN LATERAL ( SELECT round(sum(pa.allocated_ccy), 2) AS settled_ccy
           FROM payment_allocations pa
             JOIN payments p ON p.id = pa.payment_id
          WHERE pa.expense_id = c.expense_id AND p.status = 'posted'::text) a ON true
  WHERE has_permission('module.finance.view'::text) OR c.employee_id = current_user_employee();

COMMENT ON VIEW public.expense_claim_status IS
    'CLAIM-1:每一笔报销一行,而【付了没有是推导出来的】—— 与 medical_claim_status 同一条:付款状态归 expenses 所有,存一份副本第一次冲销付款时两边就分家。expense_reversed 单独露出来,因为"批准被撤销"在本刀里【没有】自己的机制:改法是冲销那笔费用(expenses 本来就有冲销路径与 reversed_by_expense),claim 的状态跟着它走 —— 两个撤销机制会对"这笔钱还欠不欠"各说各话。属主权限(security_invoker = off):它横跨 finance 与 hr(employees 有 RLS),invoker 会让读者无权的那一侧静默丢掉行,而行消失在这里意味着"少了一笔欠员工的钱"(OPS-14 修法 (a))。★ APR-ROUTE-1(F1,Tim 的 R5):行谓词写在视图里 —— has_permission(''module.finance.view'') OR employee_id = current_user_employee(),与 medical_claim_status 同形;此前它把每一笔报销交给任何一个登录的人,只靠页面自己的过滤挡着。';

-- ════════════════════════════════════════════════════════════════════════════
-- ★ COD-2(2026-09-08):从 anon 手里收回 —— 这一行必须在镜像里,不能只在迁移里 ★
-- ════════════════════════════════════════════════════════════════════════════
-- 【它此前是什么状态】ANON-0 实测:本视图是属主权限(security_invoker = off,
-- 于是基表的 RLS 根本不参与)、授给了 anon、body 里没有任何权限判据、也不调
-- 任何带门的函数。**它今天回空只因为基表还没有行。** ANON-0 的原话:
-- 它不是在漏,它是【上了膛】—— 第一条真实记录写进来的那一刻它就开了,
-- 而在此之前没有任何检查会说一句话(check_mirrors.py 第 59 行自己写着「不比 GRANT」)。
--
-- 【为什么是 REVOKE,而不是给 body 加一句 has_permission】
--   本文件上面那段注释自己写着:它【刻意只有纯 SQL、一个函数都不调】,
--   因为它要喂 operations_now —— 那是没有财务权限的人也在看的首页。
--   加一句谓词会让那些人的行【静默消失】,而"少了一个逾期承诺"与"报错"
--   完全不是一回事。那正是 OPS-14 修法 (a) 要避开的东西。
--   而 REVOKE 对 authenticated 零代价:anon 从来不是它的合法读者。
--
-- 【为什么这一行住在镜像里】db/views/batch_lineage_all.sql 的抬头记着这个疤:
--   一条只住在迁移里的 REVOKE,重建出来的库【是开着的】——「线上收着,
--   重建出来的库开着」。看着它别再漂回去的是 db/check_grants.py(COD-2)。
REVOKE ALL ON public.expense_claim_status FROM anon;

-- ═══ db/views/medical_claim_status.sql ═══
CREATE OR REPLACE VIEW public.medical_claim_status WITH (security_invoker = off) AS
 SELECT mc.id AS claim_id,
    mc.code,
    mc.employee_id,
    e.code AS employee_code,
    e.legal_name,
    mc.claim_date,
    mc.claim_year,
    mc.amount_sgd,
    mc.description,
    mc.receipt_ref,
    mc.status,
    mc.decided_at,
    mc.expense_id,
    mc.expense_id IS NOT NULL AS linked_to_expense,
    ex.code AS expense_code,
    ex.amount_base AS expense_amount_base,
    COALESCE(pay.settled_base, 0::numeric) AS settled_base,
        CASE
            WHEN mc.status <> 'approved'::text THEN mc.status
            WHEN mc.expense_id IS NULL THEN 'awaiting_payment_run'::text
            WHEN COALESCE(pay.settled_base, 0::numeric) >= (ex.amount_base + COALESCE(ex.tax_base, 0::numeric)) THEN 'paid'::text
            WHEN COALESCE(pay.settled_base, 0::numeric) > 0::numeric THEN 'part_paid'::text
            ELSE 'expense_raised'::text
        END AS settlement_state,
    ex.tax_base AS expense_tax_base
   FROM medical_claims mc
     JOIN employees e ON e.id = mc.employee_id
     LEFT JOIN expenses ex ON ex.id = mc.expense_id
     LEFT JOIN LATERAL ( SELECT sum(pa.allocated_base) AS settled_base
           FROM payment_allocations pa
             JOIN payments p ON p.id = pa.payment_id AND p.status = 'posted'::text
          WHERE pa.expense_id = ex.id) pay ON true
  WHERE mc.deleted_at IS NULL AND (has_permission('module.hr.view'::text) OR mc.employee_id = current_user_employee());

-- ═══ 删掉 expense_payable_ccy ═══
-- 它存在是为了"与过账同一个表达式";过账的那一笔税现在落在 expenses.tax_ccy 上,读者读它。
-- 五个读者都已在上面换掉(视图先换,函数才删得掉)。
DROP FUNCTION public.expense_payable_ccy(numeric, numeric);

COMMIT;

-- EQP-1b-i:预付冲抵学会【自己的币种】—— 两条支路,一条拒绝
--
-- 【这一刀在修什么】1300 预付款项由 record_payment 按【采购单的币种】记入
-- (FIN-16 的 v_pre 逐币种归集),而 apply_prepayment 一直按 base_currency_code()
-- 贷回去。两边说的不是同一种货币。
-- 【它从来不是一个错的数字,是一个错的按币种读法】1300 是 is_monetary = false,
-- 重估扫不到它,所以基准额那一栏一直是对的、总账也一直平。错的是:一笔 USD 定金
-- 被 SGD 贷记冲掉之后,1300 上那个 USD 头寸永远清不掉。
-- 【为什么是现在修】实测:线上 prepayment_applications 只有 1 行,记于 2026-07-31,
-- 而 FIN-0 把本位币从 USD 翻成 SGD 是 2026-08-04 —— 那一行是【翻转之前】的,
-- 当时 base_currency_code() 就是 USD,所以它是对的,1300 的六条行全是 USD 且净额为零。
-- 也就是说这条路自本位币翻转以来【一次都没有跑过】。改一条没跑过的路,是它最便宜的时刻。
--
-- 【新的目的地是费用单,不是资产卡】(D3'.1)应付是 record_expense 贷出来的;
-- 一台机器可以经追加模式挂上好几张费用单,而定金是冲【某一张发票】的,不是冲一台机器。
--
-- ── 两条支路一条拒绝(R1/R2/R3),判据是【应付那一侧的计价币种】────────────
-- R1 定金币种 = 应付币种 → 单位对齐:消耗 A 个单位的定金,解除 A 个单位的应付。
--    借 2000 按【应付的入账汇率】,贷 1300 按【定金的加权平均汇率】,差额进 7100。
--    付了 10,000 USD、欠 50,000 USD 的人,现在欠 40,000 USD —— 这是意图。
--    已实现汇兑是【两个历史汇率】之差,本支路不读任何当日牌价。
-- R2 两者不同、且其中恰有一个是本位币 → 价值对齐:按定金【自己的汇率】折出
--    等值的应付解除额,7100 【恒为零,是构造出来的零,不是漏算】——
--    1300 是 is_monetary = false,预付按付款那天的汇率计量、此后永不重译,
--    所以按它自己的汇率消耗它,不可能产生任何损益。本支路同样不读当日牌价。
--    【进料应付永远是本位币计价】(见 R4 的证据),所以外币采购单的定金冲进料批次
--    走的就是这一支 —— 那是本公司材料进口的常态,不是边角情况。
-- R3 两者不同、且都不是本位币 → 【按名拒绝】。只有这一种情况需要一次真正的换算,
--    而这盘生意里它不存在(国际贸易结 USD,本地结 SGD)。
--
-- 【为什么不复用 FIN-16 的换算】(D3'.5)FIN-16 算的是"一笔付款消耗多少付款币种",
-- 它要两样东西:结算日的牌价、以及一条银行行去把已实现差额轧出来。预付冲抵两样都没有
-- —— 没有钱在动,两条腿都是历史入账。复用它等于把一个当日牌价塞进一次没有发生的兑换里。
-- 复用的是它【记下来的结果】与它的列语义:
--     定金加权汇率 = Σ allocated_base / Σ allocated_ccy(该单已过账的预付核销行)
-- 不重算,直接读 —— 没有第二份公式,也就没有可漂开的第二份。
--
-- 【为什么是加权平均而不是 FIFO】(D3'.6)FIFO 要知道哪几笔定金被消耗过,那需要
-- 一张消耗台账 —— 一张表。加权平均在【按比例消耗】的模型下自洽:每次冲抵都按比例
-- 从所有定金里取,剩下的那一部分平均汇率因此恒定不变,所以"未冲抵定金的加权平均"
-- 与"全部定金的加权平均"是同一个数,不必也无法从"未冲抵的行"去算。
-- 【什么时候回来做 FIFO】同一张单上出现多笔汇率差异明显的定金成为常态时。
--
-- ── 迁移对象 ────────────────────────────────────────────────────────────────
-- 1. prepayment_applications.inbound_batch_id 去掉 NOT NULL
-- 2. + expense_id(第二个目的地)
-- 3. + currency / amount_ccy(币种三元组;amount_base 留任原意,见列注释)
-- 4. 目的地 XOR CHECK(表上,直插也逃不掉)
-- 5. 币种列的 CHECK ... NOT VALID(新行必须带,历史 NULL 原样不动)
-- 6. 遮蔽表三件套:列 + 列级 GRANT + _masked 视图(同一支迁移)
-- 7. apply_prepayment 重写(先 DROP 旧签名,再建新签名)
-- 8. ap_open_items 的费用支扣减已冲抵的预付
--
-- prepayment_applications 是【遮蔽表】:REVOKE SELECT + 列级 GRANT。
-- amount_ccy 与 amount_base 是同一笔钱的两种说法,所以它【不进列级 GRANT】,
-- 只经 _masked 视图按 data.view_prices 读;expense_id 与 currency 不是金额,授出去。

BEGIN;

-- ── 1/2/3 ───────────────────────────────────────────────────────────────────
ALTER TABLE public.prepayment_applications
    ALTER COLUMN inbound_batch_id DROP NOT NULL;

ALTER TABLE public.prepayment_applications
    ADD COLUMN expense_id uuid REFERENCES public.expenses (id),
    ADD COLUMN currency   text REFERENCES public.currencies (code),
    ADD COLUMN amount_ccy numeric;

ALTER TABLE public.prepayment_applications
    ADD CONSTRAINT prepayment_applications_amount_ccy_positive
    CHECK (amount_ccy IS NULL OR amount_ccy > 0);

-- ── 4:目的地恰一个 ─────────────────────────────────────────────────────────
-- 那一条历史行 inbound_batch_id 非空、expense_id 空 ⇒ num_nonnulls = 1,
-- 所以这条可以直接 VALID 加(实测线上 1 行,满足)。
ALTER TABLE public.prepayment_applications
    ADD CONSTRAINT prepayment_applications_one_destination
    CHECK (num_nonnulls(inbound_batch_id, expense_id) = 1);

-- ── 5:币种三元组【新行必须带】,历史 NULL 原样不动 ─────────────────────────
-- NOT VALID:对 INSERT 生效,不去碰既有行 —— FIN-32 给 inventory_ledger.business_date
-- 立"新行必填"时用的就是这个形状。
-- 【为什么不回填那一行】prepayment_applications 由守卫触发器锁死 UPDATE/DELETE。
-- 为了给一行 FIN-0 之前的测试数据"补整齐"而在迁移里绕过那个守卫,留下的正是
-- 本仓库拒绝写进迁移文件的那种旁路。它是历史,不是缺陷。
ALTER TABLE public.prepayment_applications
    ADD CONSTRAINT prepayment_applications_currency_stated
    CHECK (currency IS NOT NULL AND amount_ccy IS NOT NULL) NOT VALID;

CREATE INDEX idx_prepayment_applications_expense
    ON public.prepayment_applications (expense_id);

COMMENT ON COLUMN public.prepayment_applications.expense_id IS
'EQP-1b-i:第二个目的地 —— 这笔定金冲的是一张【费用单】的应付(设备采购的常态:
机器到货后开票,record_expense 以 unpaid 贷出 2000)。与 inbound_batch_id 恰一非空。
【为什么是费用单不是资产卡】应付是费用单贷出来的;一台机器可以经追加模式挂上
好几张费用单(运费、关税、安装),而定金冲的是某一张发票,不是一台机器。';

COMMENT ON COLUMN public.prepayment_applications.currency IS
'EQP-1b-i:本次冲抵【所陈述的币种】= 被解除的那笔应付的计价币种。
进料批次的应付恒以本位币计价(reprice_inbound_batch 按 base_currency_code() 过账),
费用单的应付以单据自己的币种计价(record_expense 按 p_currency 过账)。
历史 NULL:2026-07-31 那一行早于 FIN-0 本位币翻转,刻意未回填 —— 见
prepayment_applications_currency_stated 这条 NOT VALID 的 CHECK。';

COMMENT ON COLUMN public.prepayment_applications.amount_ccy IS
'EQP-1b-i:本次解除的应付金额,以 currency 计 —— 与 payment_allocations.allocated_ccy
同一个语义(敞口在单据币种空间恰好闭合)。费用支的敞口就是拿它来递减的。
【遮蔽】它与 amount_base 是同一笔钱的两种说法,所以不在列级 GRANT 里,
只经 prepayment_applications_masked 按 data.view_prices 读。';

COMMENT ON COLUMN public.prepayment_applications.amount_base IS
'本位币金额(以 currencies.is_base 为币种 —— 不写死币种;FIN-1a 前列名 amount_usd)。
【EQP-1b-i 把它的口径写死在这里,因为两侧从此可能不相等】它是本次消耗掉的
【定金】那一侧的本位币值 = amount_ccy × 定金加权平均汇率(R1)或
= 被解除应付的本位币值(R2,价值对齐时两侧相等)。
【为什么取定金侧】可用预付的守卫(PREPAY_INSUFFICIENT)减的就是这一列,
它必须与 payment_allocations.allocated_base 在同一个计量口径上,否则每冲一次
就漂掉一次已实现汇兑。
【进料目的地上两侧恒等】R1(两边都是本位币,汇率皆 1)与 R2(按定义价值对齐)
都让定金侧 = 应付侧,所以 ap_open_items 的进料支一直以来直接减这一列是对的,
本刀没有改变那个读法。';

COMMENT ON CONSTRAINT prepayment_applications_one_destination ON public.prepayment_applications IS
'EQP-1b-i:一次冲抵恰好有一个目的地 —— 进料批次 或 费用单。放在【表上】,
所以直插也逃不掉;apply_prepayment 另有一条同义的按名拒绝
(PREPAY_DESTINATION_INVALID),因为屏幕上不该出现裸的约束违例。';

COMMENT ON CONSTRAINT prepayment_applications_currency_stated ON public.prepayment_applications IS
'EQP-1b-i:每一条【新】冲抵都必须说出自己的币种与该币种下的金额。
NOT VALID —— 只对 INSERT 生效,不回头验既有行:线上那一行记于 2026-07-31,
早于 FIN-0(2026-08-04)的本位币翻转,是刻意留着的历史行。';

-- ── 6:遮蔽表三件套的后两件 ─────────────────────────────────────────────────
GRANT SELECT (id, purchase_order_id, inbound_batch_id, expense_id, currency,
              notes, journal_entry_id, created_at, created_by)
    ON public.prepayment_applications TO authenticated;

CREATE OR REPLACE VIEW public.prepayment_applications_masked WITH (security_invoker = off) AS
 SELECT id,
    purchase_order_id,
    inbound_batch_id,
        CASE
            WHEN has_permission('data.view_prices'::text) THEN amount_base
            ELSE NULL::numeric
        END AS amount_base,
    notes,
    journal_entry_id,
    created_at,
    created_by,
    expense_id,
    currency,
        CASE
            WHEN has_permission('data.view_prices'::text) THEN amount_ccy
            ELSE NULL::numeric
        END AS amount_ccy
   FROM prepayment_applications
  WHERE has_permission('module.finance.view'::text);

-- ── 7:apply_prepayment 重写 ────────────────────────────────────────────────
-- 先 DROP 旧签名再建新签名 —— 不是重载。preflight_migration.py 认这个形状
-- (同一文件里显式 DROP 过的旧签名不可能活下去);打错签名会让整支迁移当场中止。
DROP FUNCTION public.apply_prepayment(uuid, uuid, numeric, text);

CREATE OR REPLACE FUNCTION public.apply_prepayment(p_purchase_order_id uuid, p_inbound_batch_id uuid, p_amount numeric, p_notes text DEFAULT NULL::text, p_expense_id uuid DEFAULT NULL::uuid)
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
        SELECT e.id, e.code, e.currency, e.fx_rate, e.amount_ccy,
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
        v_open := round(v_exp.amount_ccy - v_settled, 2);
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
        CURRENT_DATE,
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

-- ── 8:ap_open_items 的费用支要扣掉已冲抵的预付 ─────────────────────────────
-- 【为什么这一条必须同刀落地】cut 4a 给进料支加这一项时写下的理由,逐字适用于
-- 费用支:"少了后一项,被定金付清的批次会永远显示未付"。设备采购的应付如果
-- 不减掉冲抵额,那台机器的欠款在账龄表上永远是全额敞口 —— 一个看得见的错数字。
-- 列集未变,故 CREATE OR REPLACE。
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
        CASE
            WHEN (CURRENT_DATE - doc_date) <= 30 THEN 'b0_30'::text
            WHEN (CURRENT_DATE - doc_date) <= 60 THEN 'b31_60'::text
            WHEN (CURRENT_DATE - doc_date) <= 90 THEN 'b61_90'::text
            ELSE 'b90_plus'::text
        END AS bucket,
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
            e.amount_base AS doc_value_base,
            round((COALESCE(s.settled, 0::numeric) + COALESCE(pp.applied, 0::numeric)) * e.fx_rate, 2) AS settled_base,
            round((e.amount_ccy - COALESCE(s.settled, 0::numeric) - COALESCE(pp.applied, 0::numeric)) * e.fx_rate, 2) AS open_base,
            e.currency,
            round(e.amount_ccy - COALESCE(s.settled, 0::numeric) - COALESCE(pp.applied, 0::numeric), 2) AS open_ccy,
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

COMMIT;

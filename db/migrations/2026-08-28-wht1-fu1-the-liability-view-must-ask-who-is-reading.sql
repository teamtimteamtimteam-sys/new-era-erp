-- db/migrations/2026-08-28-wht1-fu1-the-liability-view-must-ask-who-is-reading.sql
-- ════════════════════════════════════════════════════════════════════════════
-- WHT-1 fu1:`wht_liability_by_month` 是**属主权限**视图,却【没有问过读者是谁】。
--
-- ★【它错在哪】★ 属主权限(security_invoker = off)让视图用【视图属主】的权限
--   去读它引用的东西 —— 那正是本刀选它的理由:这张视图跨总账与 wht_remittances
--   两处,invoker 语义会让无权读总账的人【静默少算】一笔要汇的税,
--   而少算与 OPS-14 找到的那五处「行悄悄消失」是同一个病。
--
--   **但属主权限只解决"读得到吗",它不回答"谁可以读"。**
--   本视图带着 `GRANT SELECT ... TO authenticated`,于是任何一个登录用户
--   都能经 PostgREST 直接读到公司欠 IRAS 多少 —— 页面上那道
--   `requireModule(MOD.finance)` 拦的是【页面】,拦不住【表】。
--
-- ★【为什么闸没有抓住它】★ 逐条对过 db/gate.py 的判词:
--   · `colreader` 与 `xmodule` 都只看 **security_invoker** 视图 —— 属主视图
--     被它们【刻意】排除在外(那正是遮蔽视图的工作方式);
--   · `colgrant` 问的是列有没有被授权,不问谁在读;
--   · B1/B2 管的是函数的 anon 可执行性,不是视图。
--   **也就是说:一张属主权限、带 GRANT、又没有 has_permission 谓词的视图,
--   今天没有任何一条自动检查会问它一句话。** 这一条记在下面。
--
-- ★【修法就是 AGENTS.md 已经写好的那一条(OPS-14 的补救 (a))】★
--   「属主权限,并把【读者自己的模块谓词】写回视图体里」。
--   `db/views/customer_credit_status.sql` 是同一形状的先例:属主权限
--   + `has_permission('module.customers.view')` 写在体内。
--
-- 【实测过才动手,而不是"顺手加一道更严的"】(2026-08-28):
--   持有 module.finance.edit 的角色有三个(admin / gm / finance),
--   而**没有任何一个角色持有 edit 却不持有 view** —— 所以给视图加上 view 谓词,
--   不会让 remit_wht(它要 edit)读不到自己要的数。
--   remit_wht 同时显式要求 view,把这条依赖【说出来】而不是靠巧合成立:
--   它读的那张视图现在按 view 把关,那么它就该说它需要 view。
--
-- NOTE: 本文件是变更记录;安装路径完全走镜像。
-- ════════════════════════════════════════════════════════════════════════════

BEGIN;

CREATE OR REPLACE VIEW public.wht_liability_by_month
WITH (security_invoker = off) AS
WITH withheld AS (
    SELECT date_trunc('month', l.entry_date)::date AS period_month,
           SUM(l.credit - l.debit)                 AS withheld_base
      FROM journal_activity_lines('1900-01-01'::date, '2999-12-31'::date, true) l
     WHERE l.account_code = '2150'
       AND l.source_type IS DISTINCT FROM 'wht_remittance'
     GROUP BY 1
), remitted AS (
    SELECT r.period_month,
           SUM(r.amount_base) AS remitted_base
      FROM wht_remittances r
      JOIN journal_entries e ON e.id = r.journal_entry_id
     WHERE e.status = 'posted'
     GROUP BY 1
)
SELECT m.period_month,
       COALESCE(w.withheld_base, 0)                                   AS withheld_base,
       COALESCE(r.remitted_base, 0)                                   AS remitted_base,
       COALESCE(w.withheld_base, 0) - COALESCE(r.remitted_base, 0)    AS unremitted_base,
       (m.period_month + INTERVAL '1 month 14 days')::date            AS due_date,
       ((m.period_month + INTERVAL '1 month 14 days')::date < CURRENT_DATE
        AND COALESCE(w.withheld_base, 0) - COALESCE(r.remitted_base, 0) > 0) AS is_overdue
  FROM (SELECT period_month FROM withheld
        UNION
        SELECT period_month FROM remitted) m
  LEFT JOIN withheld w ON w.period_month = m.period_month
  LEFT JOIN remitted r ON r.period_month = m.period_month
 -- ★ fu1:**读者自己的模块谓词** —— 属主权限解决"读得到",这一句解决"谁可以读"。
 --   has_permission() 是 SECURITY DEFINER 且按 auth.uid() 解析,所以它答的是
 --   【调用者】,与这张视图归谁所有无关(AGENTS.md 在 OPS-14 那节写明了这一点)。
 WHERE has_permission('module.finance.view'::text);

-- ─────────────────────────────────────────────────────────────────────────────
-- remit_wht 也显式要求 view —— 把它对那张视图的依赖【说出来】
-- ─────────────────────────────────────────────────────────────────────────────
-- 少了这一句,一个持 edit 而不持 view 的角色会读到一张空视图,然后撞上
-- WHT_NOTHING_TO_REMIT —— 一句【说错了原因】的拒绝(它会说"这个月没有欠款",
-- 而真相是"你看不见它")。这个仓库对「一条答的不是它标签上那个问题的判词」
-- 已经记过五次账,这里不制造第六次。
-- db/functions/remit_wht.sql
-- WHT-1:把一个代扣月的预提税汇给 IRAS。
--
-- ★【它与 pay_payroll_cpf 是同一个形状,而那不是巧合 —— 是同一件事】★
--   两者都是【从别人的钱里扣下来、替他交给一个法定机构】:CPF 扣自员工的薪,
--   预提税扣自非居民收款人的款。所以两者的分录逐字同形(借那笔负债 / 贷银行)、
--   都在次月到期、都不豁免期间锁,而且【告警清除的条件都是钱真的动了】。
--   两个到期日不同(CPF 次月 14 日、预提税次月 15 日),各自来自各自的法令 ——
--   **不要"顺手统一"**:一个凑整过的法定期限,是一个会让公司逾期的数字。
--
-- ★【为什么不需要"先打开一期"】★ gst_periods 要先 open_gst_period 才能申报;
--   这里没有那个动作,因为【欠多少是推导出来的】(wht_liability_by_month 从总账
--   读代扣),不需要谁先声明这个月存在。于是"没有人开这一期,于是这个月的税
--   悄悄没人管"这种失败模式,在结构上不存在。
--
-- FIN-10:日期没有 CURRENT_DATE 默认值 —— 缺了就抛具名错误。默认成今天
-- 永远撞不上 PERIOD_LOCKED,于是留空反而比填对更容易过关。

CREATE OR REPLACE FUNCTION public.remit_wht(p_period_month date, p_remitted_on date DEFAULT NULL::date, p_filed_reference text DEFAULT NULL::text, p_bank_account text DEFAULT NULL::text, p_notes text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_month   date;
    v_amount  numeric;
    v_bank    text;
    v_base    text;
    v_ref     text;
    v_seq     integer;
    v_code    text;
    v_je      jsonb;
    v_id      uuid := gen_random_uuid();
BEGIN
    -- 【SECURITY DEFINER 必须自己问调用者是谁】一支不问的 definer 函数就是一条
    -- 绕过 RLS 的路。这个形状在本仓库【上线过两次、被闸抓住两次】——
    -- 写在这里是因为下一支新函数最容易漏的就是这一行。
    PERFORM require_permission('module.finance.edit');
    -- fu1:**也要求 view,而这条依赖是说出来的、不是碰巧成立的。**
    -- 本函数从 wht_liability_by_month 读欠款,而 fu1 起那张视图按
    -- module.finance.view 把关。不写这一句,一个持 edit 而不持 view 的角色
    -- 会读到一张空视图,然后撞上 WHT_NOTHING_TO_REMIT —— 一句【说错了原因】的
    -- 拒绝:它会说"这个月没有欠款",而真相是"你看不见它"。
    -- (实测 2026-08-28:线上三个持 edit 的角色 admin/gm/finance 都持 view,
    --  所以这一句今天不改变任何人的结果 —— 它防的是下一次配角色的人。)
    PERFORM require_permission('module.finance.view');

    IF p_period_month IS NULL THEN
        RAISE EXCEPTION 'WHT_PERIOD_REQUIRED';
    END IF;
    v_month := date_trunc('month', p_period_month)::date;

    IF p_remitted_on IS NULL THEN
        RAISE EXCEPTION 'WHT_REMIT_DATE_REQUIRED|%', v_month;
    END IF;
    IF p_remitted_on < v_month THEN
        -- 还没发生的代扣汇不出去。
        RAISE EXCEPTION 'WHT_REMIT_DATE_BEFORE_PERIOD|%|%', p_remitted_on, v_month;
    END IF;

    -- 【参考号必填,而 gst_periods 那一条允许空 —— 两者不是同一件事】
    -- GST 那边"申报"与"缴款"是两个动作,回执可能晚到;这里是【一次缴款】,
    -- 而一笔说不出参考号的缴款,日后对着 IRAS 无从交代。
    v_ref := NULLIF(btrim(COALESCE(p_filed_reference, '')), '');
    IF v_ref IS NULL THEN
        RAISE EXCEPTION 'WHT_FILED_REFERENCE_REQUIRED|%', v_month
          USING HINT = '填 IRAS S45 申报的回执/参考号 —— 一笔交代不出出处的缴款,日后无从对账';
    END IF;

    SELECT code INTO v_base FROM currencies WHERE is_base;

    -- 【银行必须是本位币户,而这一条【故意】比 pay_payroll_cpf 严】
    -- IRAS 只收新元。pay_payroll_cpf 允许 1010 却把两条腿都按本位币记 ——
    -- 那意味着一笔从美元户走的钱会被记成等额新元离开,而实际离开的是美元。
    -- 那一支不在本刀范围内(不顺手改别人的函数),但这一支不复制它。
    v_bank := COALESCE(p_bank_account, '1000');
    IF v_bank NOT IN ('1000','1010') THEN
        RAISE EXCEPTION 'BANK_INVALID|%', v_bank;
    END IF;
    IF bank_native_currency(v_bank) <> v_base THEN
        RAISE EXCEPTION 'WHT_REMIT_BANK_NOT_BASE|%|%', v_bank, bank_native_currency(v_bank)
          USING HINT = 'IRAS 只收本位币 —— 从外币户汇出去要先兑换,而那笔兑换是它自己的一笔交易';
    END IF;

    -- 【欠多少从那张视图读,不在这里再算一遍】视图是唯一的实现,而它对
    -- 冲销的处理(经 journal_activity_lines)是这条链上最容易写错的一段。
    -- 在这里重算 = 第二份实现,而两份会在写下来那天一致、之后悄悄分开。
    SELECT unremitted_base INTO v_amount
    FROM wht_liability_by_month WHERE period_month = v_month;

    IF COALESCE(v_amount, 0) <= 0 THEN
        RAISE EXCEPTION 'WHT_NOTHING_TO_REMIT|%|%', v_month, COALESCE(v_amount, 0)
          USING HINT = '这个月没有未汇的代扣税 —— 也可能是已经汇过了(补汇是新的一行,不是改旧的那一行)';
    END IF;

    -- 分录走【普通过账路径】,所以期间锁照常生效 —— 与 CPF 同一条:
    -- 一笔汇款不因为它是法定义务就可以进一个已经关掉的月份。
    v_je := post_journal_entry(
        p_remitted_on,
        'Withholding tax remittance ' || to_char(v_month, 'YYYY-MM'),
        'wht_remittance', v_id,
        jsonb_build_array(
            jsonb_build_object('account_code', '2150', 'side', 'debit',
                'currency', v_base, 'amount_ccy', v_amount,
                'line_memo', 'WHT for ' || to_char(v_month, 'YYYY-MM')),
            jsonb_build_object('account_code', v_bank, 'side', 'credit',
                'currency', v_base, 'amount_ccy', v_amount,
                'line_memo', 'IRAS ' || v_ref)));

    -- 编号:同一个月可以有多笔(补汇),第二笔起带序号。
    -- 咨询锁串行化,与 EXP/JE/收付款的取号手法一致。
    PERFORM pg_advisory_xact_lock(hashtext('wht_remit_' || to_char(v_month, 'YYYY-MM'))::bigint);
    SELECT COUNT(*) + 1 INTO v_seq FROM wht_remittances WHERE period_month = v_month;
    v_code := 'WHT-' || to_char(v_month, 'YYYY-MM') ||
              CASE WHEN v_seq > 1 THEN '-' || v_seq::text ELSE '' END;

    INSERT INTO wht_remittances (id, code, period_month, remitted_on, amount_base,
                                 filed_reference, journal_entry_id, notes, created_by)
    VALUES (v_id, v_code, v_month, p_remitted_on, v_amount,
            v_ref, (v_je->>'entry_id')::uuid, p_notes, auth.uid());

    RETURN jsonb_build_object(
        'remittance_id', v_id,
        'code', v_code,
        'period_month', v_month,
        'remitted_on', p_remitted_on,
        'amount_base', v_amount,
        'currency', v_base,
        'filed_reference', v_ref,
        'journal_code', v_je->>'code');
END;
$function$
;

-- ─────────────────────────────────────────────────────────────────────────────
-- record_payment:2150 的贷方 ≡ 各行 withheld_base 之和(按构造,不是靠巧合)
-- ─────────────────────────────────────────────────────────────────────────────
-- 【自查时发现的一分钱】原实现对【合计】取一次整(round(Σ withheld_pay × fx)),
-- 而落进 payment_allocations 的是【逐行】取整的值。两者在同币种下相同,
-- 跨币种时可以差一分钱 —— 而那一分钱恰好落在【表头与它的明细之间】:
-- 2150 的贷方 vs 各行 withheld_base 之和。本仓库为这件事专门有一份 fixture
-- (80「一个数字背后的那些行加起来等于那个数字」)。
-- 改成在循环里逐行累加同一个已取整的数,于是两者【按构造】相等,不靠运气。
CREATE OR REPLACE FUNCTION public.record_payment(p_direction text, p_counterparty_id uuid, p_amount numeric, p_currency text, p_fx_rate numeric DEFAULT NULL::numeric, p_bank_account text DEFAULT NULL::text, p_payment_date date DEFAULT NULL::date, p_notes text DEFAULT NULL::text, p_allocations jsonb DEFAULT '[]'::jsonb, p_counterparty_kind text DEFAULT NULL::text)
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
    PERFORM require_permission('module.finance.edit');
    IF p_payment_date IS NULL THEN
        RAISE EXCEPTION 'PAYMENT_DATE_REQUIRED';
    END IF;
    v_date := p_payment_date;
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
                SELECT i.id, i.code AS doc_code, i.customer_id AS party_id,
                       (SELECT COALESCE(sum(il.amount_ccy), 0) FROM invoice_lines il
                         WHERE il.invoice_id = i.id) AS doc_value,
                       i.currency AS doc_ccy, i.fx_rate AS doc_fx
                INTO v_doc
                FROM invoices i
                WHERE i.id = v_invoice_id AND i.kind = 'order' AND i.status = 'issued';
                IF NOT FOUND THEN
                    RAISE EXCEPTION 'ALLOC_INVALID|%', v_invoice_id;
                END IF;
                IF v_doc.party_id IS DISTINCT FROM p_counterparty_id THEN
                    RAISE EXCEPTION 'ALLOC_WRONG_PARTY|%', v_doc.doc_code;
                END IF;
                v_doc_value := v_doc.doc_value;
                v_doc_ccy := v_doc.doc_ccy; v_doc_fx := v_doc.doc_fx;
                v_key := v_invoice_id::text;

                SELECT COALESCE(SUM(pa.allocated_ccy), 0) INTO v_settled
                FROM payment_allocations pa
                JOIN payments p ON p.id = pa.payment_id AND p.status = 'posted'
                WHERE pa.invoice_id = v_invoice_id;
            ELSE
                SELECT sr.id, ob.code AS doc_code, sr.customer_id AS party_id,
                       round(sr.quantity * sr.unit_price, 2) AS doc_value,
                       sr.currency AS doc_ccy, sr.fx_rate AS doc_fx
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
                   fd.amount_ccy AS doc_value, fd.currency AS doc_ccy, fd.fx_rate AS doc_fx
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
            SELECT e.id, e.code AS doc_code, COALESCE(e.supplier_id, e.employee_id) AS party_id,
                   e.amount_ccy AS doc_value, e.currency AS doc_ccy, e.fx_rate AS doc_fx,
                   -- WHT-1:代扣率来自【债务自己冻下来的那一个】,不在这里重新解析。
                   -- 重新解析 = 第二份实现,而它会在法定税率某天变动之后,
                   -- 让一张旧债务按新税率被代扣 —— 算得出数,没有任何报错。
                   e.wht_rate_pct AS wht_rate_pct
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
            v_key := v_expense_id::text;

            SELECT COALESCE(SUM(pa.allocated_ccy), 0) INTO v_settled
            FROM payment_allocations pa
            JOIN payments p ON p.id = pa.payment_id AND p.status = 'posted'
            WHERE pa.expense_id = v_expense_id;
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
        v_alloc_base := round(v_alloc_usd * v_doc_fx, 2);
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
    v_code := fin_next_payment_code(CASE WHEN p_direction = 'in' THEN 'RCPT' ELSE 'PMT' END, v_date);

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

COMMIT;

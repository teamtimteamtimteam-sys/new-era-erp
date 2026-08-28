-- db/migrations/2026-08-28-wht1-fu2-not-subject-to-withholding-is-not-a-reason-to-refuse.sql
-- ════════════════════════════════════════════════════════════════════════════
-- WHT-1 fu2:**「不适用代扣」不是拒绝一张 paid 费用单的理由。**
--
-- ★【原实现造了一堵墙,而它自己看起来像一道闸】★
--   A2 那道拒绝(paid + 要代扣 → 按名拒,并指路"先记未付再付款")是对的。
--   但它被放在【解析税率之前】,谓词只看"有没有给性质"。于是对一个
--   **非居民收款人当场付清一笔不适用代扣的款**,两条路同时被堵死:
--     · 不回答性质      → WHT_NATURE_REQUIRED(非居民必须回答);
--     · 回答「不适用」  → WHT_ON_PAID_EXPENSE_UNSUPPORTED(paid 一律拒)。
--   **一个两边都堵死的问题不是一道闸,是一堵墙** —— 而墙的下场是有人去改数据
--   绕开它(把供应商的居民身份改回 NULL),那恰好会把这套东西整个关掉。
--
-- ★【判据改成【真的要扣钱吗】】★ 税率先解析,再按 `v_wht_rate > 0` 判。
--   没有钱要被扣下来的时候,paid 那一支没有任何东西需要劈,也就没有理由拦它。
--   条约减免到 0% 的那种情形也自然落在放行一侧,而那是对的。
--
-- 【界面本来就写对了,错的是服务端】NewExpenseForm 的提示条件一直是
--   `whtNature !== 'none' && paymentStatus === 'paid'`。两边不一致时
--   **先问哪一边错了**(AGENTS.md:「让页面同意服务端,只在服务端是对的时候才对」)
--   —— 这一次错的是服务端,所以改服务端,不是把界面改成一样严。
--
-- 【它是自查发现的,不是被闸抓到的】fixture 142 的 E 臂原本只枚举【拒绝】,
--   而这条路的正确行为是【放行】—— 一份只断言"该拒的都拒了"的 fixture,
--   对"不该拒的也被拒了"完全失明。E8 臂因此是【正着断言】的,并配一条
--   反向的自证非空转。这与 fixture 39 那条教训同族:一套只围绕
--   「规则适用时算得对吗」的测试,看不见「规则根本不该适用」。
--
-- NOTE: 本文件是变更记录;安装路径完全走镜像。
-- 【备份】本刀无数据变更、无结构变更 —— 只是一支函数体的 CREATE OR REPLACE。
--   覆盖它的备份是 2026-08-28-1729(BACKUP_EXIT=0,pg_restore --list 已验),
--   而回退这一支只需要 git 上一版 + 重放。理由写在这里而不是省略不提。
-- ════════════════════════════════════════════════════════════════════════════

BEGIN;

CREATE OR REPLACE FUNCTION public.record_expense(p_expense_date date, p_account_code text, p_amount numeric, p_currency text, p_fx_rate numeric DEFAULT NULL::numeric, p_payment_status text DEFAULT 'paid'::text, p_bank_account text DEFAULT NULL::text, p_supplier_id uuid DEFAULT NULL::uuid, p_payee_name text DEFAULT NULL::text, p_notes text DEFAULT NULL::text, p_asset jsonb DEFAULT NULL::jsonb, p_employee_id uuid DEFAULT NULL::uuid, p_purchase_order_line uuid DEFAULT NULL::uuid, p_tax_code text DEFAULT NULL::text, p_wht_nature text DEFAULT NULL::text, p_wht_rate_pct numeric DEFAULT NULL::numeric, p_wht_treaty_ref text DEFAULT NULL::text)
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
    v_bank       text;
    v_expense_id uuid := gen_random_uuid();
    v_year       integer;
    v_seq        integer;
    v_code       text;
    v_je         jsonb;
    v_asset_id   uuid;
    v_append_id  uuid;   -- FA-1a:追加模式的目标资产
    v_target     fixed_assets%ROWTYPE;
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

    -- 4. USD 金额。**p_amount 始终是【不含税净额】** —— 供应商账单上的总额
    --    是净额 + 税,而这一列记的是开支本身的价值。GST 关着时两者相等,
    --    所以这条口径对既有行为是恒等的。
    v_amount_base := round(p_amount * v_fx, 2);

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
        v_tax_ccy  := round(p_amount * v_tax_rate / 100.0, 2);
        v_tax_base := round(v_tax_ccy * v_fx, 2);
        SELECT is_claimable INTO v_claimable FROM tax_codes WHERE code = v_tax_code;
    ELSE
        -- 【未注册:与建 GST 之前一模一样】传了码要按名拒,不能悄悄忽略。
        IF NULLIF(btrim(COALESCE(p_tax_code, '')), '') IS NOT NULL THEN
            RAISE EXCEPTION 'GST_NOT_REGISTERED|%', p_tax_code;
        END IF;
    END IF;

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
        v_wht_ccy := round(p_amount * v_wht_rate / 100.0, 2);
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

    -- 【资本化口径:不可抵的进项税【是】资产成本的一部分】
    -- 可抵的税要得回来,它从来不是成本;不可抵的税(BL —— 私家车是最典型的
    -- 那一类)要不回来,于是它和买价一样是为了取得这台资产付出去的钱。
    -- 【为什么不在这里按名拒掉 BL + 资本】那会把一个【有确定答案的】会计问题
    -- 说成一个待裁决的问题。ASSET_ALREADY_IN_SERVICE 那条拒绝之所以成立,
    -- 是因为"投用后的追加是资本化改良还是当期费用"真的需要人来判;这一条不需要。
    v_cost_ccy  := round(p_amount    + CASE WHEN v_claimable THEN 0 ELSE v_tax_ccy  END, 2);
    v_cost_base := round(v_amount_base + CASE WHEN v_claimable THEN 0 ELSE v_tax_base END, 2);

    -- 5. 无缝编号:咨询锁串行化"取当年最大号+1"(同 JE/收付款编号手法);失败回滚会释放号码。
    v_year := EXTRACT(YEAR FROM p_expense_date)::integer;
    PERFORM pg_advisory_xact_lock(hashtext('expense_code_' || v_year::text)::bigint);
    SELECT COALESCE(MAX(split_part(code, '-', 3)::integer), 0) + 1
    INTO v_seq
    FROM expenses
    WHERE code LIKE 'EXP-' || v_year::text || '-%';
    v_code := 'EXP-' || v_year::text || '-' || LPAD(v_seq::text, 4, '0');

    -- 6. 先过分录(source_id = 预生成的 expense id,无需回填),期间锁在此生效。
    --    paid → 贷银行;unpaid → 贷 2000 应付。行走原币。
    -- ── GST-2:分录的形状 ────────────────────────────────────────────────
    -- 【净额那条腿带税码】F5 的 box5 = Σ(借−贷) FILTER (tax_code IN (TX,ZP,BL)),
    -- 所以它报的是【采购净额】,这正是 IRAS 要的"应税采购总额"。
    v_jlines := jsonb_build_array(
        jsonb_build_object('account_code', p_account_code, 'side', 'debit',
                           'currency', p_currency, 'amount_ccy', p_amount, 'fx_rate', v_fx,
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
        'currency', p_currency, 'amount_ccy', p_amount, 'fx_rate', v_fx);
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
                          tax_code, tax_rate_pct, tax_base,
                          -- WHT-1:裁定冻在债务上。居民身份是【抄下来的一份】,
                          -- 不是一个指向 suppliers 的引用 —— 供应商日后迁走管理与
                          -- 控制、身份跟着变,不能倒过来改写一张已经记下的债务。
                          wht_payee_residence, wht_nature, wht_rate_pct,
                          wht_amount_ccy, wht_treaty_ref)
    VALUES (v_expense_id, v_code, p_expense_date, p_account_code, p_amount, p_currency, v_fx,
            v_amount_base, p_payment_status, v_bank, p_supplier_id, p_employee_id,
            p_payee_name, p_notes, (v_je->>'entry_id')::uuid, v_user,
            p_purchase_order_line,
            v_tax_code,
            CASE WHEN v_tax_code IS NULL THEN NULL ELSE v_tax_rate END,
            v_tax_base,
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
            -- 【投用之后成本就冻住了】投用那一刻起折旧按它算;再往上加钱,
            -- 已经提过的那几期就全错了 —— 而它们已经过账,可能已经锁进期间。
            -- 投用后的追加是一次【会计判断】(资本化改良 vs 当期费用),
            -- 不是这条路顺手做得了的事,所以按名拒,把那个判断交还给人。
            IF v_target.in_service_date IS NOT NULL THEN
                RAISE EXCEPTION 'ASSET_ALREADY_IN_SERVICE|%|%', v_target.code, v_target.in_service_date;
            END IF;
            IF v_target.status <> 'active' THEN
                RAISE EXCEPTION 'ASSET_DISPOSED|%', v_target.code;
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

            RETURN jsonb_build_object(
                'expense_id', v_expense_id,
                'asset_id', v_append_id, 'asset_code', v_target.code,
                'asset_mode', 'append',
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

COMMIT;

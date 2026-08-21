-- EQP-1b-ii:费用 ↔ 采购单行的关联,以及【一条设备行只报销一次】的推导
--
-- ════════════════════════════════════════════════════════════════════════════
-- 【问题,由 EQP-1b-i 自己的勘察立下】材料靠【收货】封顶:一条材料行能被计费
-- 多少,由 inbound_batches 上真的到了多少货说了算。而设备行【按设计没有收货】
-- (guard_inbound_po_line_match 按名拒),于是今天 record_expense 会为同一台
-- 机器再记一笔 1500 借方、再累一次成本,没有任何东西反对。
--
-- 本刀把那条缺失的边补上,并在它上面立一条推导。
-- ════════════════════════════════════════════════════════════════════════════
--
-- 【expenses 不是遮蔽表 —— 查过了,不是假定的】
-- pg_class.relacl:authenticated 与 anon 都持【表级】SELECT(`arwdDxtm` 里的 r),
-- pg_attribute.attacl 全为 NULL,没有 expenses_masked 视图。
-- 对照组 purchase_order_lines:表级没有 r,13 列各有一条 attacl —— 那才是遮蔽表。
-- gate.py 的 colgrant 判据先用 cg 这个 CTE 挑出"有列授权、却没有表级授权"的表,
-- expenses 根本进不了那个集合。所以本刀【不需要】列级 GRANT,也【不需要】
-- _masked 视图 —— 四刀为这一句的缺席付过账,所以这一句写在这里,两个方向都说。
-- (AGENTS.md 那条"module.finance.view 蕴含价格可见"也早已把 expenses 点名为
--  perm2b 从未收权的五张表之一,与这次实测一致。)
--
-- ── 八个对象 ────────────────────────────────────────────────────────────────
--  1 expenses.purchase_order_line_id            新列(可空)+ 外键
--  2 idx_expenses_po_line                       普通索引(删除守卫按【全状态】查)
--  3 uq_expenses_live_po_line                   部分唯一索引 = D4 的第二层
--  4 guard_expense_po_line()                    新触发器函数 = D3 上半的表上一层
--  5 trg_expenses_po_line_kind                  BEFORE INSERT 触发器
--  6 record_expense(…, p_purchase_order_line)   先 DROP 旧签名再建(不是重载)
--  7 guard_po_line_received_floor()             删除守卫多认一种"删不得"
--  8 列注释 + 约束/索引的说明                    D5 要求写在表上的那段话
--
-- 【破窗】本刀不改任何渲染:EQP-1c 才是界面。窗口里生产跑的是旧代码 + 新库,
-- 而旧代码根本不传 p_purchase_order_line(具名参数、带默认值),所以窗口里
-- 【没有任何东西是坏的】—— 既有的开支登记逐字照旧。
--
-- 应用:./db/apply_migration.sh db/migrations/2026-08-21-eqp1bii-an-equipment-line-is-expensed-once.sql

BEGIN;

-- ════════════════════════════════════════════════════════════════════════════
-- 1 · 列
-- ════════════════════════════════════════════════════════════════════════════
ALTER TABLE public.expenses
    ADD COLUMN purchase_order_line_id uuid REFERENCES public.purchase_order_lines (id);

COMMENT ON COLUMN public.expenses.purchase_order_line_id IS
'EQP-1b-ii:这笔支出付的是【哪一条采购单行】—— 具体说,是买下那台机器的那一行。

【它是什么】设备行没有收货,所以它没有别的东西可以封顶"这条行能被计费多少"。
这一列就是那条边:一条设备行【只报销一次】(uq_expenses_live_po_line 与
record_expense 里的 PO_LINE_ALREADY_EXPENSED,两层,谓词逐字相同)。

【它不是什么 —— 这一段比上一段重要】它【不是】"一台机器只能有一笔支出"。
机器的其它成本 —— 运费、关税、安装、第三方调试验收 —— 统统挂在【资产】上,
经 record_expense 的追加模式(p_asset.asset_id)累进 fixed_asset_cost_entries,
并且【不带采购单行】(这一列为 NULL)。fixture 77 早就断言了一台机器三笔支出。
把"一行一次"读成"一台机器一次",会把资本化安装费这条正当的路堵死。

【可空,而且大多数时候就是空的】绝大多数支出根本没有采购单(水电、差旅、
月度服务费),所以这一列的常态是 NULL,不是例外。

【它管的是【行】,不是【机器】—— 说清楚,免得被读成它没做的保证】
资产卡是由一笔【新建模式】的 1500 支出生出来的,而那笔支出【不可能带这一列】:
行上的 asset_id 是外键,资产必须先存在,行才建得出来。所以"同一台机器被建成
两张资产卡"(连着两次新建模式)这条路,本刀【没有】关掉,也关不掉 ——
本刀关掉的是"同一条订单行被开两次票"。这两句话不一样,而只有后一句是真的。

【冲销之后这条行重新可计费】判据是 status = ''posted'' 一句。它站得住,是因为
guard_expense_mutation 只放行 posted→reversed 且同时首挂 reversed_by_expense、
并拒绝一切 DELETE —— 两列永远同步,所以"已冲销"在这张表上只有一种写法。

【reverse_expense 的镜像单【不得】带这一列 —— 这句是给下一个人的】
冲销镜像是一张记录凭证,不是第二张账单;它带上这一列就会立刻重新占住那条行,
而那条行的"重新可计费"是本刀的 F3 明文断言过的行为。今天它不带,是因为
reverse_expense 的 INSERT 列清单里没有它 —— 但那份清单【也漏着 employee_id】,
而补齐它已经是一件排着队的事。补那一件的人:employee_id 要补,这一列【不要】。
fixture 105 的 F3 第三条断言就是钉这一句的。';

-- ════════════════════════════════════════════════════════════════════════════
-- 2 · 两个索引,各有各的活
-- ════════════════════════════════════════════════════════════════════════════
-- 普通索引给【删除守卫】用:它要查这条行上【全部状态】的支出(已冲销的也算,
-- 因为外键照样指着),而下面那个部分索引只收 posted 的,谓词不蕴含,用不上。
CREATE INDEX idx_expenses_po_line ON public.expenses (purchase_order_line_id);

-- 硬保证:一条采购单行最多挂一笔【未冲销的】支出。
-- 【这里不需要 invoice_lines 那个冗余列】那边的部分索引要看的 void 状态住在
-- invoices 上,而部分索引的 WHERE 引用不了另一张表,所以它被迫加了一列
-- invoice_voided + 一个传播触发器。这边不用:'reversed' 就写在 expenses 自己
-- 身上。抄那个形状的【结论】(索引负责正确、函数检查负责可读),不抄它那半
-- 为跨表付的代价 —— 否则下一个人会连那半一起抄走。
CREATE UNIQUE INDEX uq_expenses_live_po_line
    ON public.expenses (purchase_order_line_id)
    WHERE purchase_order_line_id IS NOT NULL AND status = 'posted';

-- ════════════════════════════════════════════════════════════════════════════
-- 3 · D3 上半的【表上】一层
-- ════════════════════════════════════════════════════════════════════════════
-- 【为什么 D3 上半值得一个触发器,而下半不值得 —— 威胁模型不同,不是懒】
-- authenticated 对 expenses 持表级 INSERT(relacl 里的 a)且有一条 INSERT 策略,
-- 所以【直插进得来】。这正是 D4 要一个索引、而不是只靠函数检查的理由。
-- 同一个理由原样适用于"链接只能落在设备行上":一行伪造的 expenses 就足以
-- 让材料行被计一次费,而那条行还照旧走着收货计价 —— 两条路,没有对账。
-- 【下半(资产必须是行上那一台)不同】一行伪造的 expenses 【不足以】
-- 把钱记到错的机器上:那还需要第二行伪造的 fixed_asset_cost_entries。
-- 一行就能造成的伤害值一道结构保证;要两行合谋才造成的,记在函数里。
-- (真要做成结构的,得是一条 DEFERRABLE 的约束触发器 —— 成本明细是在
--  expenses 那一行【之后】才写的,INSERT 当刻看不见。留给需要它的那一刀。)
--
-- 【SECURITY DEFINER 是必须的,不是顺手加的】它要读 purchase_order_lines,
-- 而那张表的 SELECT 策略要 module.purchasing.view。一个只有财务权限的人
-- 直插一行时,以调用者身份读那张表会读到【零行】—— 于是这道守卫会把
-- "你没权限看这条行"报成 PO_LINE_NOT_FOUND,而那是 OPS-14 那条
-- "行悄悄消失"的病原样重演。属主身份读,判的才是事实。
-- 触发器函数不进 B2(verify_rebuild 明文排除 RETURNS trigger)。
CREATE OR REPLACE FUNCTION public.guard_expense_po_line()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_line record;
BEGIN
    -- 常态:绝大多数支出没有采购单行。一句就走。
    IF NEW.purchase_order_line_id IS NULL THEN
        RETURN NEW;
    END IF;

    SELECT l.id, l.line_no, l.asset_id INTO v_line
    FROM purchase_order_lines l
    WHERE l.id = NEW.purchase_order_line_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'PO_LINE_NOT_FOUND|%', NEW.purchase_order_line_id;
    END IF;

    IF v_line.asset_id IS NULL THEN
        RAISE EXCEPTION 'PO_LINE_NOT_EQUIPMENT|%', v_line.line_no;
    END IF;

    RETURN NEW;
END;
$function$;

CREATE TRIGGER trg_expenses_po_line_kind
    BEFORE INSERT ON public.expenses
    FOR EACH ROW EXECUTE FUNCTION public.guard_expense_po_line();

-- ════════════════════════════════════════════════════════════════════════════
-- 4 · record_expense —— 先 DROP 旧签名再建新签名(【不是重载】)
-- ════════════════════════════════════════════════════════════════════════════
-- preflight_migration.py 认这个形状:同一文件里、在 CREATE 之【前】显式 DROP 过
-- 的旧签名不可能活下去。打错签名会让整支迁移在单事务里当场中止。
-- (先例:2026-08-21-eqp1bi 给 apply_prepayment 加 p_expense_id 时同一手法。)
DROP FUNCTION public.record_expense(date, text, numeric, text, numeric, text, text, uuid, text, text, jsonb, uuid);

CREATE OR REPLACE FUNCTION public.record_expense(p_expense_date date, p_account_code text, p_amount numeric, p_currency text, p_fx_rate numeric DEFAULT NULL::numeric, p_payment_status text DEFAULT 'paid'::text, p_bank_account text DEFAULT NULL::text, p_supplier_id uuid DEFAULT NULL::uuid, p_payee_name text DEFAULT NULL::text, p_notes text DEFAULT NULL::text, p_asset jsonb DEFAULT NULL::jsonb, p_employee_id uuid DEFAULT NULL::uuid, p_purchase_order_line uuid DEFAULT NULL::uuid)
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
    v_asset_seq  integer;
    v_life       integer;
    v_residual   numeric;
    v_in_service date;
    v_poline     record;   -- EQP-1b-ii:这笔支出付的那一条采购单行
    v_poline_po  record;   -- 那一行所属的采购单
    v_billed     text;     -- 该行上已有的、【未冲销的】支出编号
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
        -- 【这条消息刻意【不】教人"冲销了再记一笔"】—— 实测(本刀,回滚探针):
        -- 冲销一笔【追加模式】的资本支出是【允许的】,分录冲掉了,而
        -- fixed_assets.cost_base 与那条成本明细【原样不动】(100,000 → 100,000,
        -- 明细 2 行 → 2 行)。于是"冲销再记"会把资产成本记成 170,000。
        -- 那是一个先于本刀就存在的缺陷(见 docs/known-issues.md),本刀不修它,
        -- 但绝不把它写进一句给操作员的指示里。发票与估价对不上,要改的是【订单】。
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

    -- 4. USD 金额
    v_amount_base := round(p_amount * v_fx, 2);

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
    v_je := post_journal_entry(
        p_expense_date,
        'Expense ' || v_code || ' ' || p_account_code,
        'expense', v_expense_id,
        jsonb_build_array(
            jsonb_build_object('account_code', p_account_code, 'side', 'debit',
                               'currency', p_currency, 'amount_ccy', p_amount, 'fx_rate', v_fx),
            jsonb_build_object('account_code', CASE WHEN p_payment_status = 'paid' THEN v_bank ELSE '2000' END,
                               'side', 'credit',
                               'currency', p_currency, 'amount_ccy', p_amount, 'fx_rate', v_fx))
    );

    -- 7. 插入开支单(带着分录链接一次到位;不可变表无后续 UPDATE)
    INSERT INTO expenses (id, code, expense_date, account_code, amount_ccy, currency, fx_rate,
                          amount_base, payment_status, bank_account_code, supplier_id, employee_id,
                          payee_name, notes, journal_entry_id, created_by,
                          purchase_order_line_id)
    VALUES (v_expense_id, v_code, p_expense_date, p_account_code, p_amount, p_currency, v_fx,
            v_amount_base, p_payment_status, v_bank, p_supplier_id, p_employee_id,
            p_payee_name, p_notes, (v_je->>'entry_id')::uuid, v_user,
            p_purchase_order_line);

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
            VALUES (v_append_id, v_expense_id, p_amount, p_currency, v_fx, v_amount_base, v_user);

            UPDATE fixed_assets
               SET cost_base = cost_base + v_amount_base
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
        IF COALESCE(p_asset->>'description', '') = '' THEN
            RAISE EXCEPTION 'ASSET_DESCRIPTION_REQUIRED';
        END IF;
        v_life := (p_asset->>'useful_life_months')::integer;
        IF v_life IS NULL OR v_life <= 0 THEN
            RAISE EXCEPTION 'ASSET_LIFE_INVALID|%', COALESCE(p_asset->>'useful_life_months', '?');
        END IF;
        v_residual := COALESCE((p_asset->>'residual_base')::numeric, 0);
        IF v_residual < 0 OR v_residual >= v_amount_base THEN
            RAISE EXCEPTION 'ASSET_RESIDUAL_INVALID|%|%', v_residual, v_amount_base;
        END IF;
        v_in_service := (p_asset->>'in_service_date')::date;
        IF v_in_service IS NOT NULL AND v_in_service < p_expense_date THEN
            RAISE EXCEPTION 'ASSET_IN_SERVICE_BEFORE_ACQUISITION|%|%', v_in_service, p_expense_date;
        END IF;

        v_asset_id := gen_random_uuid();
        PERFORM pg_advisory_xact_lock(hashtext('fixed_asset_code_' || v_year::text)::bigint);
        SELECT COALESCE(MAX(split_part(fa.code, '-', 3)::integer), 0) + 1
        INTO v_asset_seq
        FROM fixed_assets fa
        WHERE fa.code LIKE 'FA-' || v_year::text || '-%';
        v_asset_code := 'FA-' || v_year::text || '-' || LPAD(v_asset_seq::text, 4, '0');

        INSERT INTO fixed_assets (id, code, description, category, acquisition_date, in_service_date,
                                  cost_ccy, currency, fx_rate, cost_base, useful_life_months,
                                  residual_base, depreciation_account_code, expense_id, notes, created_by)
        VALUES (v_asset_id, v_asset_code, p_asset->>'description',
                COALESCE(p_asset->>'category', 'equipment'),
                p_expense_date, v_in_service,
                p_amount, p_currency, v_fx, v_amount_base, v_life,
                v_residual, COALESCE(p_asset->>'depreciation_account_code', '6700'),
                v_expense_id, p_asset->>'notes', v_user);

        -- 【第一笔也进明细表】否则"这台机器的成本由哪几笔构成"对第一笔要查
        -- expenses、对后续几笔要查明细表 —— 两处读法,迟早各说各话。
        INSERT INTO fixed_asset_cost_entries
            (asset_id, expense_id, amount_ccy, currency, fx_rate, amount_base, created_by)
        VALUES (v_asset_id, v_expense_id, p_amount, p_currency, v_fx, v_amount_base, v_user);
    END IF;

    RETURN jsonb_build_object(
        'expense_id', v_expense_id,
        'asset_id', v_asset_id, 'asset_code', v_asset_code,
        'code', v_code,
        'amount_base', v_amount_base,
        'journal_code', v_je->>'code',
        'payment_status', p_payment_status
    );
END;
$function$;

-- ════════════════════════════════════════════════════════════════════════════
-- 5 · 删除守卫多认一种【删不得】
-- ════════════════════════════════════════════════════════════════════════════
-- 【为什么这一条必须有】amend_purchase_order 的 remove 支会 DELETE 采购单行,
-- 而既有的守卫只挡"收过货的行" —— 设备行按设计【永远没有收货】,所以它今天
-- 一律删得掉。加上外键之后,删一条已经报销过的设备行会撞出一条【裸的 23503】,
-- 而这个仓库的规矩是屏幕上不出现裸的约束违例。BEFORE DELETE 跑在外键之前,
-- 所以按名拒绝抢得到那个位置。
--
-- 【它连【已冲销的】支出也拦 —— 而这是刻意的,不是漏了过滤】
-- 外键不认 status:一笔冲销掉的支出照样指着这条行,所以这条行照样删不掉。
-- 判据要与【结构上真的会发生的事】一致,否则就成了本仓库反复点名的那种病:
-- 标签承诺的和判据检查的不是同一件事。于是消息把两种情形分开说 ——
-- "还欠着"与"报销过、已冲销,而那条记录仍然把这行留在单上"。
-- 想让这条行消失,作废整张单;想改价,改行不删行(UPDATE 支只看数量下限,
-- 设备行的已收货恒为 0,所以改价一路畅通)。
CREATE OR REPLACE FUNCTION public.guard_po_line_received_floor()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_received numeric;
    v_line record;
    v_exp record;
BEGIN
    v_line := CASE TG_OP WHEN 'DELETE' THEN OLD ELSE NEW END;

    SELECT COALESCE(SUM(ib.quantity), 0) INTO v_received
    FROM inbound_batches ib
    WHERE ib.purchase_order_line_id = v_line.id AND ib.deleted_at IS NULL;

    IF TG_OP = 'DELETE' THEN
        -- 收过货的行不能删:那批货真的到了,单据上却没有它的出处
        IF v_received > 0 THEN
            RAISE EXCEPTION 'PO_LINE_HAS_RECEIPTS|%|%', OLD.line_no, v_received;
        END IF;
        -- EQP-1b-ii:报销过的行也不能删 —— 设备行没有收货,上面那条对它恒为假,
        -- 于是在本刀之前它一律删得掉。已冲销的照样拦(外键不认 status),
        -- 所以消息把状态一并说出来,让"为什么还拦着"是可读的。
        SELECT e.code, e.status INTO v_exp
        FROM expenses e
        WHERE e.purchase_order_line_id = OLD.id
        ORDER BY (e.status = 'posted') DESC, e.created_at
        LIMIT 1;
        IF FOUND THEN
            RAISE EXCEPTION 'PO_LINE_HAS_EXPENSE|%|%|%', OLD.line_no, v_exp.code, v_exp.status;
        END IF;
        RETURN OLD;
    END IF;

    -- 【下限是"已收",不是"零"】把订量砍到已收之下,等于让单据宣称我们订的
    -- 比实际到的还少 —— 而货已经在院子里了。等于已收是允许的(边界在内)。
    IF NEW.quantity < v_received THEN
        RAISE EXCEPTION 'PO_LINE_BELOW_RECEIVED|%|%|%', NEW.line_no, v_received, NEW.quantity;
    END IF;
    RETURN NEW;
END;
$function$;

COMMIT;

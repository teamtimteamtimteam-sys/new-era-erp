-- db/tables/expenses.sql
-- 日常开支单(6xxx 的唯一入账通道),无缝编号 'EXP-YYYY-NNNN'(record_expense 在
-- 事务内按咨询锁分配,同 JE/收付款手法)。两种入账模式:
--   * 'paid'   → 借 6xxx / 贷银行(1000/1010)—— 即付即结;
--   * 'unpaid' → 借 6xxx / 贷 2000 应付 —— 成为 AP 单据(进 ap_open_items,
--                由 record_payment 的 expense_id 核销行结算)。
-- IMMUTABLE:INSERT+SELECT RLS + 守卫触发器只放行 posted→reversed 且首挂
-- reversed_by_expense(唯一入口 reverse_expense,SECURITY DEFINER —— expenses
-- 无 UPDATE 策略)。分录链接 journal_entry_id 在插入时一次到位(expense id 预生成,
-- 分录先行,无回填 UPDATE)。冲销生成镜像单(status 'posted',notes 'REVERSAL: …',
-- 挂冲销分录,不带核销行)—— 镜像行在 ap_open_items 里被排除(它只是记录凭证)。
--
-- NOTE: introduced by db/migrations/2026-07-30-phase3-s2a-expenses.sql.
-- First-run script (plain CREATEs). Run in the Supabase SQL Editor.

CREATE TABLE public.expenses (
    id                  uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    code                text NOT NULL UNIQUE,  -- gapless 'EXP-YYYY-NNNN', assigned by record_expense
    expense_date        date NOT NULL,
    account_code        text NOT NULL REFERENCES public.accounts (code),
    amount_ccy          numeric NOT NULL CHECK (amount_ccy > 0),
    currency            text NOT NULL REFERENCES public.currencies (code),
    fx_rate             numeric NOT NULL CHECK (fx_rate > 0),
    amount_base          numeric NOT NULL,  -- round(amount_ccy × fx_rate, 2)
    payment_status      text NOT NULL CHECK (payment_status IN ('paid','unpaid')),
    bank_account_code   text CHECK (bank_account_code IN ('1000','1010')),
    supplier_id         uuid REFERENCES public.suppliers (id),
    payee_name          text,
    notes               text,
    journal_entry_id    uuid REFERENCES public.journal_entries (id),
    status              text NOT NULL DEFAULT 'posted' CHECK (status IN ('posted','reversed')),
    reversed_by_expense uuid REFERENCES public.expenses (id),
    created_at          timestamptz DEFAULT now(),
    created_by          uuid DEFAULT auth.uid(),
    -- ── PAYEE-1a 追加的列(ALTER 加的列排在末尾,与 attnum 顺序一致)──────────
    -- 往来对象的【另一半】:这笔费用欠的是员工(报销)。详见列注释。
    employee_id         uuid REFERENCES public.employees (id),
    -- ── EQP-1b-ii 追加的列(同上,排在 employee_id 之后 = live attnum 20)─────
    -- 这笔支出付的是【哪一条采购单行】。可空,而且常态就是空。详见列注释。
    -- 【外键【不在】这一行 —— 它在 db/tables/purchase_order_lines.sql 的末尾】
    -- 三张表构成一个真实的引用环:
    --     expenses.purchase_order_line_id → purchase_order_lines
    --     purchase_order_lines.asset_id   → fixed_assets      (EQP-1a)
    --     fixed_assets.expense_id         → expenses          (FIN-22)
    -- 而 check_mirrors 的 toposort 靠【文本里的 REFERENCES public.x】给表镜像排序,
    -- 环一出现它就直接退出(实测:本刀第一版把外键写在这里,它点名 24 个文件)。
    -- 所以外键与它的索引一起挪到环上【最后】被建的那张表的镜像里,由一条
    -- ALTER TABLE 补上 —— 线上的约束名 expenses_purchase_order_line_id_fkey
    -- 原样保留,两边是同一个目录事实。
    purchase_order_line_id uuid,
    -- ── GST-2 追加的列(ALTER 加的列排在末尾,与 attnum 顺序一致)──────────
    -- 【amount_ccy 始终是【不含税净额】】供应商账单上的总额 = 净额 + 税。
    -- GST 关着时两者相等,所以这条口径对既有行为是恒等的。
    -- 【可抵与不可抵是两条路】TX/ZP 的税借 1400 进项税(进 box7,要得回来);
    -- BL 的税【借开支科目本身且那条腿不带税码】—— 采购净额仍进 box5,税不进
    -- box7。"有税但要不回来"与"没有税"不是一回事,而税率分不开它们。
    -- 【资本支出上那笔不可抵的税进资产成本】它和买价一样是为取得资产付出去的钱。
    tax_code            text REFERENCES public.tax_codes (code),
    tax_rate_pct        numeric,
    tax_base            numeric NOT NULL DEFAULT 0,
    -- PAYEE-1a:往来对象【二选一】。两句话,刻意分开写:
    --   * 【从不两个】任何状态下都不许同时挂供应商与员工 —— 一笔钱不可能
    --     同时欠着两个人,悄悄挑一个会让另一个人的账凭空消失;
    --   * 【必有一个】只有 unpaid 才要求 —— 已付费用不产生应付,线上 2 笔 paid
    --     的 supplier_id 本来就是空的(实测)。把两句合成一句 `= 1`
    --     会把它们全部挡下(fixture 90 的 I 臂钉这一条)。
    CONSTRAINT expenses_counterparty_shape CHECK (
        num_nonnulls(supplier_id, employee_id) <= 1
        AND (
            (payment_status = 'paid' AND bank_account_code IS NOT NULL)
            OR (payment_status = 'unpaid'
                AND num_nonnulls(supplier_id, employee_id) = 1
                AND bank_account_code IS NULL)
        )
    ),
    -- 【三列是一件事,不是三件】
    CONSTRAINT expenses_tax_shape CHECK (
        (tax_code IS NULL     AND tax_rate_pct IS NULL     AND tax_base = 0)
     OR (tax_code IS NOT NULL AND tax_rate_pct IS NOT NULL AND tax_base >= 0))
);

COMMENT ON COLUMN public.expenses.employee_id IS 'PAYEE-1a:这笔费用欠的是【员工】(报销)。与 supplier_id 恰一非空 —— 一笔钱不可能同时欠着供应商和员工。
【它取代了 payee_name 那个自由文本吗?不完全】payee_name 仍在,它记的是"付给谁"的字面说法(FIN-26 的旧行、或一次性收款人);employee_id 是【一个指向真人的外键】,应付账因此能按人分行、能被点开。两者并存时以 employee_id 为准。
【为什么不是继续用假供应商】"Staff Reimbursements" 那个往来户把所有员工的欠款汇成一行,AP 账龄上分不出是谁、也点不开。它是 expenses_payment_shape 这条 CHECK 逼出来的变通,而本刀移除了那个必要性。';

COMMENT ON COLUMN public.expenses.purchase_order_line_id IS 'EQP-1b-ii:这笔支出付的是【哪一条采购单行】—— 具体说,是买下那台机器的那一行。

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

CREATE INDEX idx_expenses_date ON public.expenses (expense_date);
CREATE INDEX idx_expenses_supplier ON public.expenses (supplier_id);
CREATE INDEX idx_expenses_payment_status ON public.expenses (payment_status);

-- ── EQP-1b-ii:硬保证 ──────────────────────────────────────────────────────
-- (另一个索引 idx_expenses_po_line 与那条外键一起,住在
--  db/tables/purchase_order_lines.sql 的末尾 —— 理由见上面那段引用环的注释。)
-- 硬保证:一条采购单行最多挂一笔【未冲销的】支出。
-- 【这里不需要 invoice_lines 那个冗余列】那边的部分索引要看的 void 状态住在
-- invoices 上,而部分索引的 WHERE 引用不了另一张表,所以它被迫加了一列
-- invoice_voided + 一个传播触发器。这边不用:'reversed' 就写在 expenses 自己身上。
-- 抄那个形状的【结论】(索引负责正确、函数检查负责可读),不抄它那半为跨表付的
-- 代价 —— 否则下一个人会连那半一起抄走。
-- record_expense 里的 PO_LINE_ALREADY_EXPENSED 与这条索引【谓词逐字相同】。
CREATE UNIQUE INDEX uq_expenses_live_po_line
    ON public.expenses (purchase_order_line_id)
    WHERE purchase_order_line_id IS NOT NULL AND status = 'posted';

-- 守卫:只放行 posted→reversed 且首挂 reversed_by_expense,其余列逐列锁死
CREATE OR REPLACE FUNCTION public.guard_expense_mutation()
 RETURNS trigger
 LANGUAGE plpgsql
AS $function$
BEGIN
    IF TG_OP = 'DELETE' THEN
        RAISE EXCEPTION 'EXPENSE_IMMUTABLE';
    END IF;
    IF NEW.id                  IS DISTINCT FROM OLD.id
       OR NEW.code                IS DISTINCT FROM OLD.code
       OR NEW.expense_date        IS DISTINCT FROM OLD.expense_date
       OR NEW.account_code        IS DISTINCT FROM OLD.account_code
       OR NEW.amount_ccy          IS DISTINCT FROM OLD.amount_ccy
       OR NEW.currency            IS DISTINCT FROM OLD.currency
       OR NEW.fx_rate             IS DISTINCT FROM OLD.fx_rate
       OR NEW.amount_base          IS DISTINCT FROM OLD.amount_base
       OR NEW.payment_status      IS DISTINCT FROM OLD.payment_status
       OR NEW.bank_account_code   IS DISTINCT FROM OLD.bank_account_code
       OR NEW.supplier_id         IS DISTINCT FROM OLD.supplier_id
       -- PAYEE-1a fu1:往来对象的另一半,补进这份清单是为了【让清单完整】。
       -- 注意:即使少了这一行,下面那句"只放行 过账→冲销"的兜底也会拒掉
       -- 任何别的 UPDATE(实测过)—— 所以这不是在补洞,是在让这份
       -- 声称完整的枚举名副其实。两道闸各自独立,兜底放宽时清单就是唯一那道。
       OR NEW.employee_id         IS DISTINCT FROM OLD.employee_id
       OR NEW.payee_name          IS DISTINCT FROM OLD.payee_name
       OR NEW.notes               IS DISTINCT FROM OLD.notes
       OR NEW.journal_entry_id    IS DISTINCT FROM OLD.journal_entry_id
       OR NEW.created_at          IS DISTINCT FROM OLD.created_at
       OR NEW.created_by          IS DISTINCT FROM OLD.created_by
    THEN
        RAISE EXCEPTION 'EXPENSE_IMMUTABLE';
    END IF;
    IF NOT (OLD.status = 'posted' AND NEW.status = 'reversed'
            AND OLD.reversed_by_expense IS NULL AND NEW.reversed_by_expense IS NOT NULL) THEN
        RAISE EXCEPTION 'EXPENSE_IMMUTABLE';
    END IF;
    RETURN NEW;
END;
$function$;

CREATE TRIGGER trg_expenses_immutable
    BEFORE UPDATE OR DELETE ON public.expenses
    FOR EACH ROW EXECUTE FUNCTION public.guard_expense_mutation();

-- ── EQP-1b-ii:采购单行链接的【表上】守卫 ───────────────────────────────────
-- 【为什么它值得一个触发器】authenticated 对本表持表级 INSERT(relacl 里的 a)
-- 且有一条 INSERT 策略 —— 直插进得来。这正是 uq_expenses_live_po_line 要做成
-- 索引、而不是只靠函数检查的理由;同一个理由原样适用于"链接只能落在设备行上":
-- 一行伪造的 expenses 就足以让一条材料行被计一次费,而那条行还照旧走着收货计价
-- ——两条计费路,没有对账。
-- 【为什么"资产必须是行上那一台"没有做成结构保证】威胁模型不同,不是懒:
-- 一行伪造的 expenses【不足以】把钱记到错的机器上,那还需要第二行伪造的
-- fixed_asset_cost_entries。一行就能造成的伤害值一道结构保证;要两行合谋的,
-- 记在 record_expense 里。真要做成结构的,得是一条 DEFERRABLE 约束触发器
-- (成本明细是在 expenses 那一行【之后】才写的,INSERT 当刻看不见它)——
-- 那是比本刀的理由更大的一个对象,留给需要它的那一刀。
-- 【SECURITY DEFINER 是必须的,不是顺手加的】它要读 purchase_order_lines,而那张
-- 表的 SELECT 策略要 module.purchasing.view。一个只有财务权限的人直插一行时,
-- 以调用者身份读那张表会读到【零行】—— 这道守卫于是会把"你没权限看这条行"
-- 报成 PO_LINE_NOT_FOUND,正是 OPS-14 那条"行悄悄消失"原样重演。属主身份读,
-- 判的才是事实。触发器函数不进 B2(verify_rebuild 明文排除 RETURNS trigger)。
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

ALTER TABLE public.expenses ENABLE ROW LEVEL SECURITY;
CREATE POLICY "expenses select by permission"
    ON public.expenses
    AS PERMISSIVE FOR SELECT TO authenticated
    USING (has_permission('module.finance.view'::text));

CREATE POLICY "expenses insert by permission"
    ON public.expenses
    AS PERMISSIVE FOR INSERT TO authenticated
    WITH CHECK (has_permission('module.finance.edit'::text));

-- FIN-1a:改名列的注释(说明写在数据库里,重建出来的库也带着)
COMMENT ON COLUMN public.expenses.amount_base IS '本位币金额(以 currencies.is_base 为币种 —— 不写死币种;FIN-1a 前列名 amount_usd)。';

-- GST-2:未注册时写不进税码(与 invoice_lines / credit_note_lines 同一道闸)。
CREATE TRIGGER trg_expenses_tax_code_registered
    BEFORE INSERT OR UPDATE OF tax_code ON public.expenses
    FOR EACH ROW EXECUTE FUNCTION public.guard_document_tax_code();

COMMENT ON COLUMN public.expenses.tax_base IS
    'GST-2:本单的进项税,以【本位币】计。**amount_ccy 始终是不含税的净额** —— 供应商账单上的总额 = 净额 + 税。可抵的(TX/ZP)那一笔税借 1400 进项税;不可抵的(BL)【有税但要不回来】,那笔税借进费用科目本身、且【不带税码】,好让 box5 报的仍然是采购净额。';

-- ── WHT-1:预提税裁定冻在债务上(ALTER 加的列排在末尾,与 attnum 顺序一致)──
ALTER TABLE public.expenses
    ADD COLUMN wht_payee_residence text
        CHECK (wht_payee_residence IS NULL OR wht_payee_residence IN ('resident', 'non_resident')),
    ADD COLUMN wht_nature       text REFERENCES public.wht_natures (code),
    ADD COLUMN wht_rate_pct     numeric,
    ADD COLUMN wht_amount_ccy   numeric NOT NULL DEFAULT 0,
    ADD COLUMN wht_treaty_ref   text;

-- 【四列是一件事,不是四件】—— 逐字照着上面 expenses_tax_shape 那条写。
-- 最后那个合取项是承重的:一次代扣裁定只能存在于【当时收款人是非居民】的债务上。
-- 少了它,一张写着 resident 却带着税率的费用单在库里是合法的,而它算得出数。
ALTER TABLE public.expenses
    ADD CONSTRAINT expenses_wht_shape CHECK (
        (wht_nature IS NULL     AND wht_rate_pct IS NULL     AND wht_amount_ccy = 0)
     OR (wht_nature IS NOT NULL AND wht_rate_pct IS NOT NULL AND wht_amount_ccy >= 0
         AND wht_payee_residence = 'non_resident'));

COMMENT ON COLUMN public.expenses.wht_payee_residence IS
'WHT-1:**这笔债务产生的那一刻,收款人的税务居民身份**。它是从
suppliers.tax_residence 【抄】过来并冻住的一份,不是一个指向那张表的引用。

【为什么抄而不是查】与 FIN-27 把计价条款抄到承诺记录上、与 GST-2 把税率冻在
发票行上,是同一条:供应商日后改了居民身份(他确实可能改 —— 管理与控制迁走了),
不能倒过来改变一张已经记下的债务该不该代扣。查一次现在的身份,等于让历史随
主数据漂移,而且没有任何东西会说它变了。

【它是 3.1 那条裁定的物证】居民身份是【收款人】的前置条件,代扣与否是【债务】的
属性 —— 这一列就是前者变成后者的那一步。';

COMMENT ON COLUMN public.expenses.wht_nature IS
'WHT-1:这笔款在预提税上【是什么】(wht_natures.code)。NULL = 这张单不代扣。
【NULL 有两种来路,而它们在这一列上分不开,这是刻意的】① 收款人是居民,问题不成立;
② 收款人是非居民而记账人显式回答了"这一笔不代扣"。两者在账上的后果完全相同
(不扣),而把它们分成两个值会逼每一张居民供应商的费用单去回答一个不适用的问题。
真正不许发生的是【第三种】:非居民 + 没有人回答过 —— 而那一种到不了这里,
record_expense 在写之前就按名拒了(WHT_NATURE_REQUIRED)。';

COMMENT ON COLUMN public.expenses.wht_rate_pct IS
'WHT-1:适用税率,按【这张单自己的日期】从 wht_rate_for 解析出来并冻住。
条约减免时这里存的是【减免后】的税率,而 wht_treaty_ref 存那份居民证明书的编号 ——
两者要么都有、要么都没有(record_expense 里的 WHT_TREATY_REF_REQUIRED)。
【为什么不存法定税率再存一个减免值】读的人要的是"这张单扣多少",而两个数字
必须相减才得到答案的设计,会在某一天被人减错方向。法定那一个查得回来:
wht_rate_for(wht_nature, expense_date)。';

COMMENT ON COLUMN public.expenses.wht_amount_ccy IS
'WHT-1:**这张单【全额结清】时会代扣的总额**,单据币种。它是一个【预期值】,
不是账上的数 —— 真正的代扣发生在付款那一刻,按【实付的那一部分】乘税率算
(record_payment),因为法定义务是"就你付出去的那部分代扣"。
于是部分付款只扣部分,而全额付清时 Σ 各次代扣【恰好】等于这一列 ——
fixture 142 的 D 臂钉的就是这条等式。
【为什么还要存它】屏幕要在付款【之前】说得出"这张单会扣多少",而一个要靠
页面自己乘一遍才知道的数,就是第二份实现(AGENTS.md 的预览规则,已犯四次)。';

COMMENT ON COLUMN public.expenses.wht_treaty_ref IS
'WHT-1:主张税收协定(DTA)减免时,那份【居民证明书】(Certificate of Residence)的
编号。非空 ⇔ wht_rate_pct 低于当天的法定税率。

★【为什么减免是一个【要出示证据的覆盖值】,不是一张可以查的表】★
协定税率取决于:对方是不是缔约国居民、这笔款在协定里落在哪一条、以及他能不能
出具居民证明书。前两件在法条里,第三件【在对方手上】—— 没有证明书,IRAS 按
法定税率征,协定写什么都不作数。所以这不是一个"按国别 + 性质"查得出来的标量,
而是一次逐笔的判断,必须留下它凭什么成立的痕迹。
**这个仓库不判断协定适不适用**,它只保证:低于法定就必须说出凭据,而且
永远不许高于法定(WHT_TREATY_RATE_ABOVE_STATUTORY)。判断是人的。';

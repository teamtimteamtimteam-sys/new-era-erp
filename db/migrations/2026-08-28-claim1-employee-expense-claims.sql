-- CLAIM-1:员工费用报销 —— 只做【事后报销】,备用金按 Tim 的裁定【不做】
--
-- ═══════════════════════════════════════════════════════════════════════════
-- §0 · Tim 的裁定(2026-08-27),记在这里以免下一个人重新推导一遍
-- ═══════════════════════════════════════════════════════════════════════════
-- **报销与备用金是同一个问题的两个解法,而只建其中一个。**
-- 一切都在【事情发生之后】按【实际花掉的钱】报销:不预支备用金、不对备用金
-- 余额、离职时也不用追回备用金。六个人的规模,事后报销够用 ——
-- 而且它【天然带着一道审批】,而备用金是在任何人看到收据【之前】就把钱交出去。
-- 队列里那一条写的是「一般费用报销与备用金」;备用金是【被否决的】,不是被推迟的。
--
-- ═══════════════════════════════════════════════════════════════════════════
-- §1 · 实测:这条链【今天已经通到底了】—— 缺的不是应付,是【请求与决定】
-- ═══════════════════════════════════════════════════════════════════════════
--   员工自己掏钱 → 公司欠他 → 公司付给他
--   · **公司欠他**:`expenses.employee_id` 早就有,而且表上那条 CHECK 要求
--     payment_status='unpaid' 时 num_nonnulls(supplier_id, employee_id) = 1 ——
--     一笔未付费用【恰好】挂一个往来对象,员工是头等公民(PAYEE-1a)。
--   · **看得见**:`ap_open_items` 里带着员工自己的名字。PAYEE-1a 之前那里是
--     INNER JOIN suppliers,员工那一行【整行消失】—— fixture 90 守着这件事,
--     它的原话是「消失比空白更坏」。
--   · **付得掉**:`record_payment` 的出款侧显式允许 'employee'
--     (`v_kind NOT IN ('supplier','employee')` 才拒)。
--   实测线上:员工应付 0 笔、供应商应付 4 笔、expenses 共 6 笔。
--
-- **所以本刀建的不是应付,是它前面那两步:一个【请求】和一次【决定】。**
-- 今天只有持财务权限的人能调 record_expense —— 员工【张不了口】,也没有人批。
--
-- ═══════════════════════════════════════════════════════════════════════════
-- §2 · 为什么另起一张表,而不是扩 medical_claims
-- ═══════════════════════════════════════════════════════════════════════════
-- medical_claims 是一套【完整的】五支函数流程(submit / decide / pay /
-- balance / code),形状与这一刀要的几乎一样。**唯一真正属于医疗的是那条
-- 年度限额** —— decide_medical_claim 按 medical_claim_balance 算出剩余额度,
-- 超了就 CLAIM_EXCEEDS_LIMIT。那不是一个字段,是一条【规矩】,而且它的来源
-- 在 HR 那一侧(HR-6 的年度权益)。
-- 而一般报销需要三样医疗那边没有的东西:**科目码、币种、税码**。
-- 把两者合成一张表,等于让每一个读它的人先问一句"这一行是哪一种",
-- 而答案在另一个模块里。所以:**另起一张,但把两者做成一对而不是两个陌生人**
-- —— 同样的动词、同样的状态词、同样的决定字段。
--
-- ═══════════════════════════════════════════════════════════════════════════
-- §3 · ★【一道闸只守它当时那条路】★ —— guard_payment_sod 的那条豁免
-- ═══════════════════════════════════════════════════════════════════════════
-- SOD-1 的 guard_payment_sod 【明确豁免了付给员工的款】,理由写在它自己体内:
--     「出款给【员工】(报销)由 HR 建档、财务付款,已经跨了两个模块的门,
--       不是同一个人端到端。」
-- **那句话在它写下的那天是对的,而本刀让它不再覆盖全部情形** ——
-- CLAIM-1 开出了一条新路:**员工【自己】发起**,财务批准并付款。
-- 「跨了两个模块」这个论证对新路不成立,因为发起人现在就是受益人。
-- 这正是 AGENTS.md 记的那一族(GST-2 撞过两次):
--     **换了推导来源,闸就要跟着搬。**
-- 处置:把职责分离【搬到决定那一步】—— 提报的人不能批自己那一笔,
-- 由 assert_segregated 执行(SOD-1 立的那条规矩本身,第三个调用方)。
-- guard_payment_sod 那条豁免【不动】(它对 HR 建档那条路仍然成立),
-- 但它的注释在本刀里改了一句:说明报销这条路现在在【上游】被守着。
--
-- 【为什么不要求"批的人不能付"】线上 finance 角色【只有一个持有人】,
-- 而他本人就是员工 EMP-2026-0001。再加一道"批≠付",每一笔批过的报销
-- 都将【永远付不出去】—— 一条让公司停摆的控制最后会被关掉,而关掉之后
-- 什么都没守住。这一条写下来,是因为它是一个【决定】,不是一个疏漏。

BEGIN;

-- ───────────────────────────────────────────────────────────────────────────
-- 1 · expense_claims —— 一次请求,一次决定
-- ───────────────────────────────────────────────────────────────────────────
CREATE TABLE public.expense_claims (
    id                uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    code              text NOT NULL UNIQUE,
    employee_id       uuid NOT NULL REFERENCES public.employees (id) ON DELETE RESTRICT,
    -- ★【花钱的那一天是世界上的一个事实,绝不默认】★ AGENTS.md 那条:
    -- 一个决定期间/汇率/金额的日期给它 CURRENT_DATE 默认值,就是奖励留空 ——
    -- 填对的那天可能撞上期间锁而报错,留空的反而滑进开着的月份。
    spend_date        date NOT NULL,
    -- 【提交时刻可以默认】它记的是"这条记录什么时候被建出来",不是世界上的事实。
    submitted_at      timestamptz NOT NULL DEFAULT now(),
    amount_ccy        numeric NOT NULL CHECK (amount_ccy > 0),
    currency          text NOT NULL REFERENCES public.currencies (code),
    description       text NOT NULL,
    -- 【凭据:要么有附件,要么有一句说得出为什么没有】见 §4
    no_receipt_reason text,
    status            text NOT NULL DEFAULT 'submitted'
        CHECK (status IN ('submitted', 'withdrawn', 'approved', 'rejected')),
    withdrawn_at      timestamptz,
    -- ══ 决定 ══════════════════════════════════════════════════════════════
    decided_at        timestamptz,
    decided_by        uuid,
    decision_notes    text,
    -- ★【会计口径由【审批人】给,不由提报人给】★
    -- 提报人陈述【事实】(买了什么、哪天、多少钱、凭据);
    -- 审批人陈述【会计】(记哪个科目、哪个税码)。一个员工不可能知道科目表,
    -- 而进项税可不可抵(BL 是不可抵)是一个财务判断,不是一个可以猜的东西。
    account_code      text REFERENCES public.accounts (code),
    tax_code          text REFERENCES public.tax_codes (code),
    -- 入账日:默认就是花钱那天(成本属于它发生的那个期间)。
    -- 只有当那个期间已经关账时,审批人才【显式】给一个别的日子 —— 而不是
    -- 让它悄悄滑进开着的月份。
    posting_date      date,
    expense_id        uuid REFERENCES public.expenses (id),
    created_at        timestamptz NOT NULL DEFAULT now(),
    created_by        uuid,
    -- 【批准 ⇔ 有那笔费用】两边必须同时成立:批了却没有费用 = 公司答应了却
    -- 没有记下这笔债;有费用却没批 = 一笔没人授权的支出。
    CONSTRAINT expense_claims_approved_shape
        CHECK ((status = 'approved') = (expense_id IS NOT NULL)),
    CONSTRAINT expense_claims_decision_shape
        CHECK ((decided_at IS NULL) = (decided_by IS NULL)),
    -- 【驳回必须给理由】一条没有理由的驳回,提报人无从判断该改了再交还是算了
    CONSTRAINT expense_claims_reject_reason
        CHECK (status <> 'rejected' OR btrim(COALESCE(decision_notes, '')) <> ''),
    CONSTRAINT expense_claims_withdraw_shape
        CHECK ((status = 'withdrawn') = (withdrawn_at IS NOT NULL))
);

COMMENT ON TABLE public.expense_claims IS
    'CLAIM-1:员工费用报销的【请求】与【决定】。★【备用金是被否决的,不是被推迟的】★(Tim 2026-08-27):一切事后按实际花掉的钱报销 —— 不预支、不对余额、离职不用追回;六个人的规模够用,而且事后报销天然带一道审批,备用金则是在任何人看到收据之前就把钱交出去。【为什么另起一张表而不是扩 medical_claims】那一套是完整可用的五支函数流程,形状几乎一样,但它唯一属于医疗的东西是【年度限额】—— 那不是字段是规矩,来源在 HR 侧;而一般报销要科目码、币种、税码,医疗一个都没有。合成一张表就得让每个读者先问"这一行是哪一种",答案却在另一个模块。【链路的其余部分早就有了】公司欠员工 = expenses.employee_id(PAYEE-1a,表上 CHECK 保证未付时恰好一个往来对象);看得见 = ap_open_items 带员工名(fixture 90 守着,它的原话是"消失比空白更坏");付得掉 = record_payment 出款侧显式允许 employee。所以本刀建的只是前面两步。【一笔报销一笔费用】claim → expense 一对一,应付因此追得回是谁提的。多行的出差报三笔。';

COMMENT ON COLUMN public.expense_claims.account_code IS
    'CLAIM-1:记哪个科目 —— 由【审批人】在批准那一刻给,不由提报人给。提报人陈述事实,审批人陈述会计。一个员工不可能知道科目表,而他随手选错的科目,最后还是要财务来改。';

COMMENT ON COLUMN public.expense_claims.posting_date IS
    'CLAIM-1:入账日。【默认就是 spend_date】—— 成本属于它发生的那个期间。只有当那个期间已经关账、record_expense 会按名拒(PERIOD_LOCKED)时,审批人才【显式】给一个别的日子。这里刻意【不做】自动回落到当月:那正是 FIN-10 拆掉的那种默认 —— 填对的日子会报错、留空的反而滑进开着的月份,于是这条路在奖励留空。';

CREATE INDEX idx_expense_claims_employee ON public.expense_claims (employee_id, spend_date DESC);
CREATE INDEX idx_expense_claims_open ON public.expense_claims (status) WHERE status = 'submitted';

ALTER TABLE public.expense_claims ENABLE ROW LEVEL SECURITY;

-- 【读:财务看得见全部,员工看得见自己的】与 my_profile / medical 同一条思路。
CREATE POLICY "expense_claims select by permission" ON public.expense_claims
    AS PERMISSIVE FOR SELECT TO authenticated
    USING (has_permission('module.finance.view'::text)
        OR employee_id = current_user_employee());

-- 【没有 INSERT/UPDATE/DELETE 策略】唯一写入口是三支属主权限函数。

-- ───────────────────────────────────────────────────────────────────────────
-- 2 · 凭据挂在哪儿:finance_attachments 加一列(它【不是】遮蔽表)
-- ───────────────────────────────────────────────────────────────────────────
-- 实测:finance_attachments 走的是【表级】授权(relacl 里有 r),没有 _masked
-- 伴生视图。所以这一列不需要 CASHFLOW-1 那种"三件事一支迁移"——
-- 表级 INSERT/UPDATE 授权自动延伸到后加的列,SELECT 也是表级的。
-- 说出来而不是默认它:同一个仓库里 purchase_order_payment_terms 就是另一种,
-- 而两者的区别只能靠查 relacl 与 _masked 得到。
ALTER TABLE public.finance_attachments
    ADD COLUMN claim_id uuid REFERENCES public.expense_claims (id);

COMMENT ON COLUMN public.finance_attachments.claim_id IS
    'CLAIM-1:这份附件属于哪一笔报销申请。沿用本表既有的【每种主体一列可空外键】写法(sales_record_id / inbound_batch_id / payment_id / expense_id),不另起 (subject_type, subject_id) —— 一张表里两种写法比任何一种单独用都坏。';

-- ★【加一列还不够 —— 这张表上有一条"恰好一个父亲"的不变量】★
-- finance_attachments_one_parent 写的是
--   num_nonnulls(sales_record_id, inbound_batch_id, payment_id, expense_id) = 1
-- 新列不在里面,于是一份【只挂在报销申请上】的附件会撞上这条 CHECK。
-- 这与遮蔽表那一课是同一个形状:**给一张带不变量的表加列,那条不变量
-- 要在同一支迁移里跟着改** —— 否则新列写得进表结构、写不进一行数据。
-- 是干跑当场撞出来的,而不是等到 gate。
ALTER TABLE public.finance_attachments
    DROP CONSTRAINT finance_attachments_one_parent,
    ADD CONSTRAINT finance_attachments_one_parent
        CHECK (num_nonnulls(sales_record_id, inbound_batch_id, payment_id, expense_id, claim_id) = 1);

CREATE INDEX idx_finance_attachments_claim ON public.finance_attachments (claim_id)
    WHERE claim_id IS NOT NULL;

-- ───────────────────────────────────────────────────────────────────────────
-- 3 · 取号器(与 next_medical_claim_code / next_statement_code 同一惯用法)
-- ───────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.next_expense_claim_code(p_date date DEFAULT CURRENT_DATE)
 RETURNS text LANGUAGE plpgsql SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE v_year integer := EXTRACT(YEAR FROM p_date)::integer; v_seq integer;
BEGIN
    PERFORM pg_advisory_xact_lock(hashtext('expense_claim_code_' || v_year::text)::bigint);
    SELECT COALESCE(MAX(split_part(code, '-', 3)::integer), 0) + 1 INTO v_seq
      FROM expense_claims WHERE code LIKE 'CLM-' || v_year::text || '-%';
    RETURN 'CLM-' || v_year::text || '-' || LPAD(v_seq::text, 4, '0');
END;
$function$;

-- ───────────────────────────────────────────────────────────────────────────
-- 4 · submit_expense_claim —— 员工自己张口的那一步
-- ───────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.submit_expense_claim(
    p_employee_id       uuid,
    p_spend_date        date,
    p_amount            numeric,
    p_currency          text,
    p_description       text,
    p_no_receipt_reason text DEFAULT NULL
)
 RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE v_emp employees%ROWTYPE; v_code text; v_id uuid;
BEGIN
    -- 【自助:本人,或者持财务读权限的人代录】与 submit_medical_claim 同一条谓词
    IF NOT (has_permission('module.finance.view') OR p_employee_id = current_user_employee()) THEN
        RAISE EXCEPTION 'PERMISSION_DENIED|module.finance.view';
    END IF;

    SELECT * INTO v_emp FROM employees WHERE id = p_employee_id AND deleted_at IS NULL;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'EMPLOYEE_NOT_FOUND|%', COALESCE(p_employee_id::text, '?');
    END IF;
    IF p_spend_date IS NULL THEN
        RAISE EXCEPTION 'EXPENSE_CLAIM_SPEND_DATE_REQUIRED';
    END IF;
    IF p_spend_date > CURRENT_DATE THEN
        -- 一笔"将来才会花的钱"不是报销,那是备用金 —— 而备用金被否决了(§0)
        RAISE EXCEPTION 'EXPENSE_CLAIM_SPEND_DATE_FUTURE|%|%', p_spend_date::text, CURRENT_DATE::text;
    END IF;
    IF p_amount IS NULL OR p_amount <= 0 THEN
        RAISE EXCEPTION 'EXPENSE_CLAIM_AMOUNT_INVALID|%', COALESCE(p_amount::text, '?');
    END IF;
    IF p_currency IS NULL OR NOT EXISTS (SELECT 1 FROM currencies WHERE code = p_currency) THEN
        RAISE EXCEPTION 'EXPENSE_CLAIM_CURRENCY_UNKNOWN|%', COALESCE(p_currency, '?');
    END IF;
    IF p_description IS NULL OR btrim(p_description) = '' THEN
        -- 「买了什么」是审批人唯一能据以判断的东西
        RAISE EXCEPTION 'EXPENSE_CLAIM_DESCRIPTION_REQUIRED';
    END IF;

    v_code := next_expense_claim_code(p_spend_date);
    INSERT INTO expense_claims (code, employee_id, spend_date, amount_ccy, currency,
                                description, no_receipt_reason, created_by)
    VALUES (v_code, p_employee_id, p_spend_date, p_amount, p_currency,
            btrim(p_description),
            NULLIF(btrim(COALESCE(p_no_receipt_reason, '')), ''), auth.uid())
    RETURNING id INTO v_id;

    RETURN jsonb_build_object('claim_id', v_id, 'code', v_code, 'status', 'submitted');
END;
$function$;

COMMENT ON FUNCTION public.submit_expense_claim(uuid, date, numeric, text, text, text) IS
    'CLAIM-1:员工提一笔报销。【花钱那天必填、不默认】—— 它是世界上的一个事实,而给它一个 CURRENT_DATE 默认值就是奖励留空(AGENTS.md / FIN-10)。【未来的花销按名拒】一笔"将来才会花的钱"不是报销,那是备用金,而备用金被 Tim 否决了。【自助谓词与 submit_medical_claim 逐字相同】本人,或持 module.finance.view 的人代录。【凭据不在这一步查】提交那一刻附件还没处上传(申请还不存在),所以"要么有附件要么说得出为什么没有"这条在【批准】那一步执行 —— 那也正是凭据真正起作用的时刻。';

-- ───────────────────────────────────────────────────────────────────────────
-- 5 · withdraw_expense_claim —— 可以撤回,不能改
-- ───────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.withdraw_expense_claim(p_claim_id uuid)
 RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE v_c expense_claims%ROWTYPE;
BEGIN
    SELECT * INTO v_c FROM expense_claims WHERE id = p_claim_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'EXPENSE_CLAIM_NOT_FOUND|%', COALESCE(p_claim_id::text, '?');
    END IF;
    IF NOT (has_permission('module.finance.edit') OR v_c.employee_id = current_user_employee()) THEN
        RAISE EXCEPTION 'PERMISSION_DENIED|module.finance.edit';
    END IF;
    IF v_c.status <> 'submitted' THEN
        RAISE EXCEPTION 'EXPENSE_CLAIM_NOT_SUBMITTED|%|%', v_c.code, v_c.status;
    END IF;

    UPDATE expense_claims
       SET status = 'withdrawn', withdrawn_at = now()
     WHERE id = p_claim_id;
    RETURN jsonb_build_object('claim_id', p_claim_id, 'code', v_c.code, 'status', 'withdrawn');
END;
$function$;

COMMENT ON FUNCTION public.withdraw_expense_claim(uuid) IS
    'CLAIM-1:把一笔还没决定的报销撤回。★【可以撤回,不能改】★ —— 一笔已经有人看过的申请被悄悄改掉,是【另一笔申请套着同一个号】。撤回再交一次,两件事都留在记录上。';

-- ───────────────────────────────────────────────────────────────────────────
-- 6 · decide_expense_claim —— 决定,而【批准那一刻就是记账那一刻】
-- ───────────────────────────────────────────────────────────────────────────
-- ★【成本与欠款【同时】在批准那一刻确认】★
-- 批下去,公司就欠这笔钱了 —— 所以批准是记【成本】与记【对员工的债】
-- 这两件事诚实的时刻,而不是更晚的某一步。
-- 医疗那边把它放在第三步(pay_medical_claim 其实并不付钱,它建的是一笔
-- unpaid 的费用);这一刀把它并进批准,因为"批了、但账上什么都没有"
-- 是一个公司已经答应、却没有记下来的债。
--
-- ★【入账日 = 花钱那天】★ 成本属于它发生的那个期间。那个期间关了账,
-- record_expense 会按名拒(PERIOD_LOCKED)—— 那时审批人【显式】给一个
-- posting_date,而不是让它悄悄滑进开着的月份(FIN-10 拆掉的正是那种默认)。
CREATE OR REPLACE FUNCTION public.decide_expense_claim(
    p_claim_id     uuid,
    p_approve      boolean,
    p_account_code text DEFAULT NULL,
    p_tax_code     text DEFAULT NULL,
    p_posting_date date DEFAULT NULL,
    p_notes        text DEFAULT NULL
)
 RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_c        expense_claims%ROWTYPE;
    v_emp      employees%ROWTYPE;
    v_actors   uuid[];
    v_has_att  boolean;
    v_exp      jsonb;
    v_date     date;
BEGIN
    PERFORM require_permission('module.finance.edit');

    SELECT * INTO v_c FROM expense_claims WHERE id = p_claim_id FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'EXPENSE_CLAIM_NOT_FOUND|%', COALESCE(p_claim_id::text, '?');
    END IF;
    IF v_c.status <> 'submitted' THEN
        RAISE EXCEPTION 'EXPENSE_CLAIM_NOT_SUBMITTED|%|%', v_c.code, v_c.status;
    END IF;
    SELECT * INTO v_emp FROM employees WHERE id = v_c.employee_id;

    -- ══ ★【职责分离:提报的人不能批自己那一笔】★ ══════════════════════════
    -- 【为什么这道闸必须新装在这里】SOD-1 的 guard_payment_sod 明确豁免了
    -- 付给员工的款,理由是"由 HR 建档、财务付款,已经跨了两个模块的门"。
    -- 那句话在写下的那天是对的 —— 而本刀开出了一条新路:**员工自己发起**。
    -- 发起人现在就是受益人,那个论证对新路不成立。
    -- 「换了推导来源,闸就要跟着搬」(AGENTS.md;GST-2 撞过两次)。
    -- 【第一步的主语有两个】受益人(员工自己的 user_id)与提报人(created_by):
    -- 代人录入时两者不同,而两者都不该是批准的那个人。
    v_actors := ARRAY(
        SELECT x FROM unnest(ARRAY[v_emp.user_id, v_c.created_by]) x WHERE x IS NOT NULL);
    PERFORM assert_segregated('EXPENSE_CLAIM_SELF_APPROVAL', v_actors, v_c.code);

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
        RETURN jsonb_build_object('claim_id', p_claim_id, 'code', v_c.code, 'status', 'rejected');
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
        p_tax_code       := NULLIF(btrim(COALESCE(p_tax_code, '')), ''));

    UPDATE expense_claims
       SET status = 'approved', decided_at = now(), decided_by = auth.uid(),
           decision_notes = NULLIF(btrim(COALESCE(p_notes, '')), ''),
           account_code = btrim(p_account_code),
           tax_code = NULLIF(btrim(COALESCE(p_tax_code, '')), ''),
           posting_date = v_date,
           expense_id = (v_exp->>'expense_id')::uuid
     WHERE id = p_claim_id;

    RETURN jsonb_build_object('claim_id', p_claim_id, 'code', v_c.code, 'status', 'approved',
                              'expense_id', v_exp->>'expense_id', 'posting_date', v_date);
END;
$function$;

COMMENT ON FUNCTION public.decide_expense_claim(uuid, boolean, text, text, date, text) IS
    'CLAIM-1:批或驳一笔报销。★【批准那一刻就是记账那一刻】★ —— 批下去公司就欠这笔钱了,所以成本与对员工的债在这一刻【同时】确认,而不是更晚的某一步(医疗那边放在第三步,于是"批了但账上什么都没有"会存在一段时间)。★【职责分离新装在这里】★ SOD-1 的 guard_payment_sod 明确豁免了付给员工的款,理由是"HR 建档、财务付款,跨了两个模块";本刀开出了一条【员工自己发起】的新路,那个论证对它不成立 —— 换了推导来源,闸就要跟着搬(GST-2 撞过两次)。第一步的主语取【受益人 + 提报人】两个。不加"批≠付":线上 finance 只有一个持有人且他本人就是员工,再加一道会让每一笔批过的报销永远付不出去,而一条让公司停摆的控制最后会被关掉。【凭据查在批准这一步】提交时附件还挂不上去;而凭据起作用的时刻正是有人据它做决定的时刻。允许没有收据,但必须说出为什么 —— 一条没有例外出口的规矩会被绕过,而这里绕过的走法是"当成普通费用直接录",那会把整条报销记录一起丢掉。【入账日】默认花钱那天(成本属于它发生的期间);期间关了账 record_expense 按名拒,那时审批人显式给一个日子,而不是让它滑进开着的月份。';

-- ───────────────────────────────────────────────────────────────────────────
-- 7 · expense_claim_status —— 「付了没有」是【推导】出来的,不是存下来的
-- ───────────────────────────────────────────────────────────────────────────
-- 与 medical_claim_status 同一条:付款状态归 expenses 所有。存一份副本,
-- 第一次冲销付款时两边就分家了。
CREATE OR REPLACE VIEW public.expense_claim_status
WITH (security_invoker = off) AS
SELECT c.id                AS claim_id,
       c.code,
       c.employee_id,
       e.code              AS employee_code,
       e.legal_name        AS employee_name,
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
       x.status = 'reversed'                       AS expense_reversed,
       COALESCE(a.settled_ccy, 0)                  AS settled_ccy,
       -- ★【"付了没有"看的是【核销额】,不是 payment_status】★
       -- 实测(干跑时 G 臂当场抓到的):record_payment 结清一笔费用时【不动】
       -- expenses.payment_status。那一列记的是【入账方式】——
       -- 'paid' = 录入当时就付掉了(直接出账),'unpaid' = 记成一笔应付;
       -- 它【不是】"后来结清了没有"。把它当结清状态读,是"一个字段其实
       -- 指着另一件事"那一类错误,而它会在付完款之后仍然报"还欠着"。
       -- 真正记录结清的是 payment_allocations,而 ap_open_items 的应付额
       -- 正是【金额 − 核销额】。
       -- 【为什么不直接读 ap_open_items】那张视图体内用 has_permission 把门,
       -- 而这张视图要给【员工看自己那一笔】—— 一个没有 module.finance.view 的
       -- 员工去读它会一行都拿不到,于是他自己的报销永远显示"没付"。
       -- 所以这里照它【费用那一支】的算法取同一个和(单表一次求和),
       -- 而不是把整张视图搬过来。
       (c.status = 'approved' AND x.status = 'posted'
        AND COALESCE(a.settled_ccy, 0) >= x.amount_ccy)  AS is_paid,
       (c.status = 'approved' AND x.status = 'posted'
        AND COALESCE(a.settled_ccy, 0) <  x.amount_ccy)  AS is_owing,
       EXISTS (SELECT 1 FROM finance_attachments fa
                WHERE fa.claim_id = c.id AND fa.deleted_at IS NULL) AS has_receipt
  FROM expense_claims c
  JOIN employees e   ON e.id = c.employee_id
  LEFT JOIN expenses x ON x.id = c.expense_id
  LEFT JOIN LATERAL (
        SELECT round(sum(pa.allocated_ccy), 2) AS settled_ccy
          FROM payment_allocations pa
          JOIN payments p ON p.id = pa.payment_id
         WHERE pa.expense_id = c.expense_id AND p.status = 'posted'
  ) a ON true;

COMMENT ON VIEW public.expense_claim_status IS
    'CLAIM-1:每一笔报销一行,而【付了没有是推导出来的】—— 与 medical_claim_status 同一条:付款状态归 expenses 所有,存一份副本第一次冲销付款时两边就分家。expense_reversed 单独露出来,因为"批准被撤销"在本刀里【没有】自己的机制:改法是冲销那笔费用(expenses 本来就有冲销路径与 reversed_by_expense),claim 的状态跟着它走 —— 两个撤销机制会对"这笔钱还欠不欠"各说各话。属主权限(security_invoker = off):它横跨 finance 与 hr(employees 有 RLS),invoker 会让读者无权的那一侧静默丢掉行,而行消失在这里意味着"少了一笔欠员工的钱"(OPS-14 修法 (a));调用方按 module.finance.view 或本人把关。';

COMMIT;

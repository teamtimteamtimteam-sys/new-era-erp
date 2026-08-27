-- db/tables/expense_claims.sql
-- CLAIM-1：员工费用报销的请求与决定（备用金按 Tim 的裁定不做）。
--
-- NOTE: introduced by db/migrations/2026-08-28-claim1-employee-expense-claims.sql.
-- First-run script (plain CREATEs).

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

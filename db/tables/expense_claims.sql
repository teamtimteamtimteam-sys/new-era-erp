-- db/tables/expense_claims.sql
-- CLAIM-1：员工费用报销的请求与决定（备用金按 Tim 的裁定不做）。
-- ★ EXPENSE-MULTILINE-1(Tim 2026-10-20,Step 0 Q3 · Step 0b Q1–Q10):一张报销单是【表头 + 明细】。本表是表头:报销人 · 币种
--   (一张单一个币种,Q4)· 用途(description,必填,搜索读它,Q7)· 状态与决定 · 合计。每一笔明细(日期 · 金额 · 说明 ·
--   无收据理由,批准时由财务给的科目与税码)在 expense_claim_items。批准时一张报销单生出【一张】费用单,每一笔明细是它的一行。
--   spend_date = 最晚那一笔明细的日期、amount_ccy = 明细之和 —— 由 guard_expense_claim_totals 在提交时强制;它们决定审批档次、
--   默认入账日与汇率(Q5)。account_code / tax_code / no_receipt_reason 从表头搬到了明细(每一笔各自的)。
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
    -- ★ EXPENSE-MULTILINE-1:最晚那一笔明细的日期(guard_expense_claim_totals 强制)。
    spend_date        date NOT NULL,
    -- 【提交时刻可以默认】它记的是"这条记录什么时候被建出来",不是世界上的事实。
    submitted_at      timestamptz NOT NULL DEFAULT now(),
    amount_ccy        numeric NOT NULL CHECK (amount_ccy > 0),   -- ★ EXPENSE-MULTILINE-1:明细之和
    currency          text NOT NULL REFERENCES public.currencies (code),
    -- ★ EXPENSE-MULTILINE-1:这一句是整张单的【用途】(Q7,必填,搜索读它);每一笔明细有自己的说明。
    --   【凭据:要么有附件,要么有一句说得出为什么没有】那一列(no_receipt_reason)搬到了每一笔明细上。
    description       text NOT NULL,
    status            text NOT NULL DEFAULT 'submitted'
        CHECK (status IN ('submitted', 'withdrawn', 'approved', 'rejected')),
    withdrawn_at      timestamptz,
    -- ══ 决定 ══════════════════════════════════════════════════════════════
    decided_at        timestamptz,
    decided_by        uuid,
    decision_notes    text,
    -- ★【会计口径由【审批人】给,不由提报人给】★ —— ★ EXPENSE-MULTILINE-1:科目与税码【按明细】给,
    -- 住在 expense_claim_items(Tim Step 0b Q1:财务在批准时给每一笔,什么都不预选)。
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
    'CLAIM-1:员工费用报销的【请求】与【决定】。★【备用金是被否决的,不是被推迟的】★(Tim 2026-08-27):一切事后按实际花掉的钱报销 —— 不预支、不对余额、离职不用追回;六个人的规模够用,而且事后报销天然带一道审批,备用金则是在任何人看到收据之前就把钱交出去。【为什么另起一张表而不是扩 medical_claims】那一套是完整可用的五支函数流程,形状几乎一样,但它唯一属于医疗的东西是【年度限额】—— 那不是字段是规矩,来源在 HR 侧;而一般报销要科目码、币种、税码,医疗一个都没有。合成一张表就得让每个读者先问"这一行是哪一种",答案却在另一个模块。【链路的其余部分早就有了】公司欠员工 = expenses.employee_id(PAYEE-1a,表上 CHECK 保证未付时恰好一个往来对象);看得见 = ap_open_items 带员工名(fixture 90 守着,它的原话是"消失比空白更坏");付得掉 = record_payment 出款侧显式允许 employee。所以本刀建的只是前面两步。【一笔报销一笔费用】claim → expense 一对一,应付因此追得回是谁提的。~~多行的出差报三笔~~ ★ EXPENSE-MULTILINE-1(Tim 2026-10-20):一张报销单可以有多笔明细(expense_claim_items),批准时生出【一张】费用单、每笔明细一行;仍然是一张报销单对一张费用单。';

COMMENT ON COLUMN public.expense_claims.posting_date IS
    'CLAIM-1:入账日。【默认就是 spend_date】—— 成本属于它发生的那个期间。只有当那个期间已经关账、record_expense 会按名拒(PERIOD_LOCKED)时,审批人才【显式】给一个别的日子。这里刻意【不做】自动回落到当月:那正是 FIN-10 拆掉的那种默认 —— 填对的日子会报错、留空的反而滑进开着的月份,于是这条路在奖励留空。';

CREATE INDEX idx_expense_claims_employee ON public.expense_claims (employee_id, spend_date DESC);
CREATE INDEX idx_expense_claims_open ON public.expense_claims (status) WHERE status = 'submitted';


-- SEARCH-2 · 迁移 A:code 上的 trigram GIN —— 买的是【后缀匹配】(`%0001`)。
-- btree 服务得了后缀(强制走索引时规划器会选 code_key 做 Bitmap Index Scan),
-- 但它 seek 不了;今天 319 行上量不出差别,合成 20 万行时 12.0ms vs 33.4ms。
-- 扩展由 db/platform-prelude.sql §4 提供(连同那条 search_path)。
CREATE INDEX expense_claims_code_trgm ON public.expense_claims USING gin (code extensions.gin_trgm_ops);

-- SEARCH-4 · 迁移 B:关联搜索走这一列。为将来的体量建,不为今天的毫秒数
--(320 行上规划器一律 Seq Scan;理由与迁移 A/C 逐字同族)。
CREATE INDEX expense_claims_expense_id_rel ON public.expense_claims (expense_id);
ALTER TABLE public.expense_claims ENABLE ROW LEVEL SECURITY;

-- 【读:财务看得见全部,员工看得见自己的】与 my_profile / medical 同一条思路。
CREATE POLICY "expense_claims select by permission" ON public.expense_claims
    AS PERMISSIVE FOR SELECT TO authenticated
    USING (has_permission('module.finance.view'::text)
        OR employee_id = current_user_employee());

-- 【没有 INSERT/UPDATE/DELETE 策略】唯一写入口是三支属主权限函数。

-- ── EXPENSE-MULTILINE-1(Tim 2026-10-20,Step 0b Q5):表头的合计与日期【就是】明细推出来的那一个 ─────────────────
-- amount_ccy = 明细之和;spend_date = 最晚那一笔明细的日期;至少一笔。与 guard_expense_totals 同一个形状(延迟的约束触发器,
-- 两张表各挂一条,同一支函数),理由也相同:表头先插、明细后插,"等不等"只在两边都写完之后才答得了。
-- 表头的 spend_date 决定审批档次(expense_claim_amount_base)、默认入账日与汇率 —— 它不能与明细各说各话。
CREATE OR REPLACE FUNCTION public.guard_expense_claim_totals()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_id uuid;
    v_h  record;
    v_s  record;
BEGIN
    IF TG_TABLE_NAME = 'expense_claims' THEN
        v_id := NEW.id;
    ELSE
        v_id := NEW.claim_id;
    END IF;
    SELECT c.code, c.amount_ccy, c.spend_date INTO v_h FROM expense_claims c WHERE c.id = v_id;
    IF NOT FOUND THEN
        RETURN NULL;
    END IF;
    SELECT count(*) AS n, COALESCE(sum(i.amount_ccy), 0) AS amount_ccy, max(i.spend_date) AS spend_date
      INTO v_s FROM expense_claim_items i WHERE i.claim_id = v_id;
    IF v_s.n = 0 THEN
        RAISE EXCEPTION 'EXPENSE_CLAIM_HAS_NO_ITEMS|%', v_h.code;
    END IF;
    IF v_h.amount_ccy IS DISTINCT FROM v_s.amount_ccy OR v_h.spend_date IS DISTINCT FROM v_s.spend_date THEN
        RAISE EXCEPTION 'EXPENSE_CLAIM_TOTALS_MISMATCH|%|header %/%|items %/%', v_h.code,
            v_h.amount_ccy, v_h.spend_date, v_s.amount_ccy, v_s.spend_date;
    END IF;
    RETURN NULL;
END;
$function$;

-- 表头没有不可改守卫(决定那一步要改状态),所以这一条也挂在【改合计或日期】上。
CREATE CONSTRAINT TRIGGER trg_expense_claims_totals_match
    AFTER INSERT OR UPDATE OF amount_ccy, spend_date ON public.expense_claims
    DEFERRABLE INITIALLY DEFERRED
    FOR EACH ROW EXECUTE FUNCTION public.guard_expense_claim_totals();

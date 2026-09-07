-- db/views/expense_claim_status.sql
-- CLAIM-1：每一笔报销一行，而「付了没有」是从核销额【推导】出来的。
--
-- ★ WITH (security_invoker = off) 与 COMMENT ON VIEW 都是【手工补回来的】★
-- pg_get_viewdef() 只吐 SELECT —— 既不吐 reloptions，也不吐对象注释。
-- 照它重建镜像会把两样都悄悄丢掉（AGENTS.md 为前者记过一次；后者是
-- STATEMENT-1 漏过、CHASE-1-FU 补上的那一条）。
--
-- NOTE: introduced by db/migrations/2026-08-28-claim1-employee-expense-claims.sql.

CREATE VIEW public.expense_claim_status WITH (security_invoker = off) AS
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
    c.status = 'approved'::text AND x.status = 'posted'::text AND COALESCE(a.settled_ccy, 0::numeric) >= x.amount_ccy AS is_paid,
    c.status = 'approved'::text AND x.status = 'posted'::text AND COALESCE(a.settled_ccy, 0::numeric) < x.amount_ccy AS is_owing,
    (EXISTS ( SELECT 1
           FROM finance_attachments fa
          WHERE fa.claim_id = c.id AND fa.deleted_at IS NULL)) AS has_receipt
   FROM expense_claims c
     JOIN employees e ON e.id = c.employee_id
     LEFT JOIN expenses x ON x.id = c.expense_id
     LEFT JOIN LATERAL ( SELECT round(sum(pa.allocated_ccy), 2) AS settled_ccy
           FROM payment_allocations pa
             JOIN payments p ON p.id = pa.payment_id
          WHERE pa.expense_id = c.expense_id AND p.status = 'posted'::text) a ON true;

COMMENT ON VIEW public.expense_claim_status IS
    'CLAIM-1:每一笔报销一行,而【付了没有是推导出来的】—— 与 medical_claim_status 同一条:付款状态归 expenses 所有,存一份副本第一次冲销付款时两边就分家。expense_reversed 单独露出来,因为"批准被撤销"在本刀里【没有】自己的机制:改法是冲销那笔费用(expenses 本来就有冲销路径与 reversed_by_expense),claim 的状态跟着它走 —— 两个撤销机制会对"这笔钱还欠不欠"各说各话。属主权限(security_invoker = off):它横跨 finance 与 hr(employees 有 RLS),invoker 会让读者无权的那一侧静默丢掉行,而行消失在这里意味着"少了一笔欠员工的钱"(OPS-14 修法 (a));调用方按 module.finance.view 或本人把关。';

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

-- db/views/expense_claim_status.sql
-- CLAIM-1：每一笔报销一行，而「付了没有」是从核销额【推导】出来的。
--
-- ★ WITH (security_invoker = off) 与 COMMENT ON VIEW 都是【手工补回来的】★
-- pg_get_viewdef() 只吐 SELECT —— 既不吐 reloptions，也不吐对象注释。
-- 照它重建镜像会把两样都悄悄丢掉（AGENTS.md 为前者记过一次；后者是
-- STATEMENT-1 漏过、CHASE-1-FU 补上的那一条）。
--
-- ════════════════════════════════════════════════════════════════════════════
-- ★★★ APR-ROUTE-1 · F1(Tim 的 R5,2026-09-23):这张视图此前把【每一笔】报销
--     交给【任何一个】登录的人 ★★★
-- ════════════════════════════════════════════════════════════════════════════
-- 【它是什么形状】属主权限(security_invoker = off),于是 expense_claims 的 RLS
-- 根本不参与;而函数体【没有任何行谓词】。EMP-SELF-0 §3 以 fusheng(warehouse,
-- 不持 module.finance.view)的真身份实测:看得见 4 行 —— 线上全部 4 行,
-- 跨 2 名员工,带姓名、金额、事由。/me 只是因为页面自己加了
-- `.eq('employee_id', …)` 才没有在屏幕上露出来 —— 一道只在【页面】上的过滤,
-- 对一个直接调 PostgREST 的人什么都不是。
--
-- 【谓词】与 medical_claim_status 逐字同形:财务看全部,其余每个人只看自己的。
--   has_permission('module.finance.view') OR employee_id = current_user_employee()
-- ★ 两个都按【调用者】求值(两者都是 SECURITY DEFINER、读 auth.uid()),
--   所以属主权限不会把它们变成"属主看得见的一切"。
--
-- 【下面 COD-2 那段理由,在这张视图上是【假】的,照直更正】它说"本视图要喂
-- operations_now,加谓词会让没有财务权限的人的行静默消失"。EMP-SELF-0 §3 与
-- APR-ROUTE-1 grilling 各查一遍:`grep expense_claim_status` 在 db/views、
-- db/functions、app、lib 里只命中两处 —— app/me/page.tsx(本人)与
-- app/finance/claims/page.tsx(页闸 module.finance.view)。**没有任何视图或函数
-- 读它。** 于是这一句谓词没有让任何一个合法读者少一行。
-- ☞ 那段话大概是从 collection_promise_status(同一次 COD-2 一起收权的另一张)
--   上抄过来的。它留在下面,因为 REVOKE FROM anon 那一句仍然对 —— 错的只是理由。
--
-- 【一个读者真的少了行:db/fixtures/196 的 F0b】它以 postgres、清空 claims 的身份
-- 读这张视图来自证"视图里有东西"。postgres 没有 JWT → has_permission 恒假、
-- current_user_employee() 为 NULL → 0 行 → F0b 响亮地报"前提不成立"。
-- 同一刀里改成以一个持 module.finance.view 的身份读(Tim 的 Q11)。
--
-- NOTE: introduced by db/migrations/2026-08-28-claim1-employee-expense-claims.sql.

-- AP-RECON-1(2026-09-24):「付清了没有」对着【净额 + 进项税】判(CLAIM-GST-1 起读 amount_ccy + tax_ccy,
-- 落库的那一笔税;此前是 expense_payable_ccy 重算)——
-- CLAIM-GST-1 还在末尾【追加】两列 expense_net_ccy / expense_tax_ccy(费用单上的净额与税):
-- 批准之后,屏幕要说得出员工报的那个总额被拆成了什么 —— 读落库的两个数,不在页面上再算一遍。
-- 只追加、不动既有列序 → 迁移走 CREATE OR REPLACE。
-- 那是总账 2000 上欠员工的全部;只对着净额判,会在那笔税还欠着的时候说"已付"。
-- (报销的税是【从报销额里拆出来】的 —— CLAIM-GST-1,2026-09-24:decide_expense_claim 传
--  p_amount_includes_tax := true,于是 amount_ccy + tax_ccy 恰好等于员工报的那个总额。)

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

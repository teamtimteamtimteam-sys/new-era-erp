-- db/views/medical_claim_status.sql
-- 医疗报销一览。HR 看全部,员工看自己的。
-- settlement_state 从【已过账的付款分配】推导 —— 与 ap_open_items 用同一个信号,
-- 因为 expenses.payment_status 对"建单时未付、之后经付款流程结清"的费用不会翻转。
--
-- NOTE: updated by db/migrations/2026-08-02-hr2b-leave-exceptions-and-claims.sql.

-- AP-RECON-1(2026-09-24):「付清」对着【净额 + 进项税】的本位币判(amount_base + tax_base,
-- 过账时存下的两个数)—— 与 ap_open_items 的费用支 doc_value_base 同一个数。
--
-- CLAIM-GST-1(2026-09-24):末尾【追加】expense_tax_base —— 申报额是含税总额,税从里面拆出来;
-- 建了费用之后,详情页读 expense_amount_base(净额)与它,说得出那个总额被拆成了什么。
-- 医疗申报只收本位币,所以本位币两个数就是单据上的两个数。只追加 → CREATE OR REPLACE。

CREATE VIEW public.medical_claim_status WITH (security_invoker = off) AS
 SELECT mc.id AS claim_id,
    mc.code,
    mc.employee_id,
    e.code AS employee_code,
    e.legal_name,
    mc.claim_date,
    mc.claim_year,
    mc.amount_sgd,
    mc.description,
    mc.receipt_ref,
    mc.status,
    mc.decided_at,
    mc.expense_id,
    mc.expense_id IS NOT NULL AS linked_to_expense,
    ex.code AS expense_code,
    ex.amount_base AS expense_amount_base,
    COALESCE(pay.settled_base, 0::numeric) AS settled_base,
        CASE
            WHEN mc.status <> 'approved'::text THEN mc.status
            WHEN mc.expense_id IS NULL THEN 'awaiting_payment_run'::text
            WHEN COALESCE(pay.settled_base, 0::numeric) >= (ex.amount_base + COALESCE(ex.tax_base, 0::numeric)) THEN 'paid'::text
            WHEN COALESCE(pay.settled_base, 0::numeric) > 0::numeric THEN 'part_paid'::text
            ELSE 'expense_raised'::text
        END AS settlement_state,
    ex.tax_base AS expense_tax_base
   FROM medical_claims mc
     JOIN employees e ON e.id = mc.employee_id
     LEFT JOIN expenses ex ON ex.id = mc.expense_id
     LEFT JOIN LATERAL ( SELECT sum(pa.allocated_base) AS settled_base
           FROM payment_allocations pa
             JOIN payments p ON p.id = pa.payment_id AND p.status = 'posted'::text
          WHERE pa.expense_id = ex.id) pay ON true
  WHERE mc.deleted_at IS NULL AND (has_permission('module.hr.view'::text) OR mc.employee_id = current_user_employee());

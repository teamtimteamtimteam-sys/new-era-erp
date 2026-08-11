-- FRT-1 第四部分(2026-08-11):未付运费进应付账龄 —— 第三种单据类型
--
-- 【为什么它不是可选的】一张未付的运费单贷 2000,而 ap_open_items 的应付明细
-- 只从 inbound_batches 与 expenses 推。少了这一支,那笔钱【在总账里躺着,
-- 在账龄表上不存在】—— 一个既有余额、又查不到明细的应付,正是这个仓库反复
-- 找到的那类无声缺口。
--
-- 【付款要能核销它】payment_allocations 因此多一列 freight_document_id,
-- 与既有的 sales_record_id / inbound_batch_id / expense_id 同级:三选一变四选一。
-- 不加这一列,运费应付会【永远挂着】,因为没有任何一条路能把它结掉。
--
-- 【页面一起给】/finance/payables 的行按 doc_kind 分岔到详情页;
-- 只加支不加页,会得到一张"看得见总数、点不开"的应付 —— 而"没有地方可去"
-- 比"链接指错了"更难被发现:读的人会去查数据,而不是去找那张不存在的页面。
-- (LINKS-1 的分岔让"不加页"是安全的 —— 安全不等于完整。)

BEGIN;

-- 付款核销的第四个去处
ALTER TABLE public.payment_allocations
    ADD COLUMN freight_document_id uuid REFERENCES public.freight_documents (id);

COMMENT ON COLUMN public.payment_allocations.freight_document_id IS
    'FRT-1:这笔核销冲的是一张运费单(对手方是货代)。与 sales_record_id / inbound_batch_id / expense_id / purchase_order_id 同级 —— 五者恰一非空。';

-- 【五选一,不是四选一】少改这条约束,新列就永远插不进去(旧约束要求恰一非空,
-- 而它不认识新列)—— 一个"加了列却用不了"的静默失败。
ALTER TABLE public.payment_allocations DROP CONSTRAINT payment_allocations_one_target;
ALTER TABLE public.payment_allocations ADD CONSTRAINT payment_allocations_one_target
    CHECK (num_nonnulls(sales_record_id, inbound_batch_id, expense_id, purchase_order_id, freight_document_id) = 1);

CREATE OR REPLACE VIEW public.ap_open_items WITH (security_invoker = off) AS
 SELECT doc_kind,
    doc_id,
    doc_code,
    inbound_batch_id,
    supplier_id,
    supplier_name,
    doc_date,
    doc_value_base,
    settled_base,
    open_base,
    currency,
    open_ccy,
    CURRENT_DATE - doc_date AS days_outstanding,
        CASE
            WHEN (CURRENT_DATE - doc_date) <= 30 THEN 'b0_30'::text
            WHEN (CURRENT_DATE - doc_date) <= 60 THEN 'b31_60'::text
            WHEN (CURRENT_DATE - doc_date) <= 90 THEN 'b61_90'::text
            ELSE 'b90_plus'::text
        END AS bucket
   FROM ( SELECT 'inbound'::text AS doc_kind,
            ib.id AS doc_id,
            ib.code AS doc_code,
            ib.id AS inbound_batch_id,
            ib.supplier_id,
            sup.legal_name AS supplier_name,
            COALESCE(ib.arrival_date, ib.created_at::date) AS doc_date,
            round(ib.quantity * ib.unit_price, 2) AS doc_value_base,
            round(COALESCE(s.settled, 0::numeric) + COALESCE(pp.applied, 0::numeric), 2) AS settled_base,
            round(round(ib.quantity * ib.unit_price, 2) - COALESCE(s.settled, 0::numeric) - COALESCE(pp.applied, 0::numeric), 2) AS open_base,
            ( SELECT c.code
                   FROM currencies c
                  WHERE c.is_base) AS currency,
            round(round(ib.quantity * ib.unit_price, 2) - COALESCE(s.settled, 0::numeric) - COALESCE(pp.applied, 0::numeric), 2) AS open_ccy
           FROM inbound_batches_masked ib
             JOIN suppliers sup ON sup.id = ib.supplier_id
             LEFT JOIN LATERAL ( SELECT sum(pa.allocated_ccy) AS settled
                   FROM payment_allocations pa
                     JOIN payments p ON p.id = pa.payment_id AND p.status = 'posted'::text
                  WHERE pa.inbound_batch_id = ib.id) s ON true
             LEFT JOIN LATERAL ( SELECT sum(ppa.amount_base) AS applied
                   FROM prepayment_applications_masked ppa
                  WHERE ppa.inbound_batch_id = ib.id) pp ON true
          WHERE ib.deleted_at IS NULL AND ib.unit_price IS NOT NULL
        UNION ALL
         SELECT 'expense'::text AS doc_kind,
            e.id AS doc_id,
            e.code AS doc_code,
            NULL::uuid AS inbound_batch_id,
            e.supplier_id,
            sup.legal_name AS supplier_name,
            e.expense_date AS doc_date,
            e.amount_base AS doc_value_base,
            round(COALESCE(s.settled, 0::numeric) * e.fx_rate, 2) AS settled_base,
            round((e.amount_ccy - COALESCE(s.settled, 0::numeric)) * e.fx_rate, 2) AS open_base,
            e.currency,
            round(e.amount_ccy - COALESCE(s.settled, 0::numeric), 2) AS open_ccy
           FROM expenses e
             JOIN suppliers sup ON sup.id = e.supplier_id
             LEFT JOIN LATERAL ( SELECT sum(pa.allocated_ccy) AS settled
                   FROM payment_allocations pa
                     JOIN payments p ON p.id = pa.payment_id AND p.status = 'posted'::text
                  WHERE pa.expense_id = e.id) s ON true
          WHERE e.payment_status = 'unpaid'::text AND e.status = 'posted'::text AND NOT (EXISTS ( SELECT 1
                   FROM expenses o
                  WHERE o.reversed_by_expense = e.id))
        UNION ALL
         SELECT 'freight'::text AS doc_kind,
            fd.id AS doc_id,
            fd.code AS doc_code,
            NULL::uuid AS inbound_batch_id,
            fd.supplier_id,
            sup.legal_name AS supplier_name,
            fd.doc_date,
            fd.amount_base AS doc_value_base,
            round(COALESCE(s.settled, 0::numeric) * fd.fx_rate, 2) AS settled_base,
            round((fd.amount_ccy - COALESCE(s.settled, 0::numeric)) * fd.fx_rate, 2) AS open_base,
            fd.currency,
            round(fd.amount_ccy - COALESCE(s.settled, 0::numeric), 2) AS open_ccy
           FROM freight_documents fd
             JOIN suppliers sup ON sup.id = fd.supplier_id
             LEFT JOIN LATERAL ( SELECT sum(pa.allocated_ccy) AS settled
                   FROM payment_allocations pa
                     JOIN payments p ON p.id = pa.payment_id AND p.status = 'posted'::text
                  WHERE pa.freight_document_id = fd.id) s ON true
          WHERE fd.payment_status = 'unpaid'::text AND fd.status = 'posted'::text
            AND fd.deleted_at IS NULL) d
  WHERE open_ccy > 0::numeric AND has_permission('module.finance.view'::text);;

COMMIT;

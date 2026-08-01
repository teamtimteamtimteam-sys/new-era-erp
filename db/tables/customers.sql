-- db/tables/customers.sql
-- 客户主档。code 'CUS-YYYY-NNNN' 由 BEFORE INSERT 触发器从序列取号(注意:序列取号
-- 不是无缝的 —— 回滚会烧号。主档编号无审计连号要求,财务单据才用咨询锁连号方案)。
-- 软删除 deleted_at;status 自由文本(draft/active 等,无状态机 —— 供应商侧才有)。
-- 注意线上【没有】updated_at 触发器(建表早期漏挂,updated_at 靠应用层写)——
-- 镜像忠实于线上;要补触发器请走迁移,别只改这里。
--
-- NOTE: 本表早于"迁移 + 镜像"约定(建库初期直接在 Supabase SQL Editor 建的),
-- 一直没有镜像文件;2026-07-31 镜像漂移审计后【按线上目录重建】了本文件。
-- payment_terms_days 为 db/migrations/2026-07-31-phase4-cut2a-invoices.sql 追加;
-- email / phone / contact_person 为 db/migrations/2026-07-31-phase4-cut2b-customer-contacts.sql
-- 追加(列序按线上 attnum,追加列在末尾,勿按语义位置重排 —— 镜像审计按序比对)。
-- First-run script (plain CREATEs). Run in the Supabase SQL Editor.

CREATE SEQUENCE public.customer_code_seq;

CREATE TABLE public.customers (
    id                 uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    code               text NOT NULL UNIQUE,  -- 'CUS-YYYY-NNNN',触发器取号
    legal_name         text NOT NULL,
    short_name         text,
    country            text NOT NULL,
    tax_id             text,
    address            text,
    customer_types     text[],
    payment_terms      text,
    incoterm           text,
    credit_rating      text,
    notes              text,
    status             text NOT NULL DEFAULT 'draft',
    deleted_at         timestamptz,
    created_at         timestamptz NOT NULL DEFAULT now(),
    created_by         uuid,
    updated_at         timestamptz NOT NULL DEFAULT now(),
    updated_by         uuid,
    payment_terms_days integer CHECK (payment_terms_days IS NULL OR (payment_terms_days >= 0 AND payment_terms_days <= 365)),
    email              text,
    phone              text,
    contact_person     text
);

CREATE OR REPLACE FUNCTION public.generate_customer_code()
RETURNS trigger LANGUAGE plpgsql AS $function$
BEGIN
    IF NEW.code IS NULL OR NEW.code = '' THEN
        NEW.code := 'CUS-' || EXTRACT(YEAR FROM NOW())::TEXT || '-' ||
                    LPAD(nextval('customer_code_seq')::TEXT, 4, '0');
    END IF;
    RETURN NEW;
END;
$function$;

CREATE TRIGGER trg_generate_customer_code
    BEFORE INSERT ON public.customers
    FOR EACH ROW EXECUTE FUNCTION generate_customer_code();

ALTER TABLE public.customers ENABLE ROW LEVEL SECURITY;
CREATE POLICY "customers select by permission"
    ON public.customers
    AS PERMISSIVE FOR SELECT TO authenticated
    USING (has_permission('module.customers.view'::text));

CREATE POLICY "customers insert by permission"
    ON public.customers
    AS PERMISSIVE FOR INSERT TO authenticated
    WITH CHECK (has_permission('module.customers.edit'::text));

CREATE POLICY "customers update by permission"
    ON public.customers
    AS PERMISSIVE FOR UPDATE TO authenticated
    USING (has_permission('module.customers.edit'::text)) WITH CHECK (has_permission('module.customers.edit'::text));

CREATE POLICY "customers delete by permission"
    ON public.customers
    AS PERMISSIVE FOR DELETE TO authenticated
    USING (has_permission('module.customers.edit'::text));

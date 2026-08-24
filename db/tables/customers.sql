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
    contact_person     text,
    -- ── SAL-B 追加的列(ALTER 加的列排在末尾,与 attnum 顺序一致)──────────
    -- 【NULL = 没设限额(放行);0 = 现款现货(任何赊销都拒)—— 相反,不是相近】。
    -- 全部既有客户为 NULL:管控按客户逐个启用,首日什么都不拦。变动由触发器留痕。
    credit_limit_base numeric CHECK (credit_limit_base IS NULL OR credit_limit_base >= 0),
    credit_hold boolean NOT NULL DEFAULT false,
    -- ── GST-2 追加的列(ALTER 加的列排在末尾,与 attnum 顺序一致)──────────
    -- 【初值 NULL,而 NULL 不是一个默认值,是一个【没有人回答过】的问题】——
    -- 已注册时开票会按名拒(TAX_CODE_REQUIRED|customer)。一个悄悄默认的税码
    -- 是一个穿着默认值外衣的错答案,而它算得出数、报得出表,不会有任何一条报错。
    -- 【尤其不按国别自动推 ZR】出口零税率在法定上取决于【出口证据】,
    -- 不取决于账单地址 —— 按国别推等于把一个证据问题答成一个地址问题。
    -- 侧别由 trg_customers_default_tax_code_side 钉住:销项码才挂得上来。
    default_tax_code text REFERENCES public.tax_codes (code)
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

CREATE UNIQUE INDEX customers_tax_id_unique ON public.customers (tax_id) WHERE tax_id IS NOT NULL AND deleted_at IS NULL;

CREATE TRIGGER trg_customers_normalise_identity
    BEFORE INSERT OR UPDATE ON public.customers
    FOR EACH ROW EXECUTE FUNCTION public.normalise_counterparty_identity();

COMMENT ON COLUMN public.customers.tax_id IS
    '登记号/税号(新加坡 UEN、中国统一社会信用代码)。**这是这一行的身份**,不是名字 —— GO-4。写入时去空白并大写;非空且未软删的行上唯一。【不是必填】,理由同 suppliers.tax_id,必填留给批量导入那一刀。';

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

-- SAL-B:限额/冻结变动留痕(函数体在 db/functions/log_customer_credit_change.sql)
CREATE TRIGGER trg_customers_credit_history
    BEFORE UPDATE OF credit_limit_base, credit_hold ON public.customers
    FOR EACH ROW EXECUTE FUNCTION public.log_customer_credit_change();

COMMENT ON COLUMN public.customers.credit_limit_base IS
    '信用限额,以本位币计(SAL-B)。【NULL = 没设限额(放行);0 = 现款现货(任何赊销都拒)—— 两个都正当,而且相反】。全部既有客户为 NULL:管控按客户逐个启用,首日什么都不拦 —— 空效果是设计,不是坏了。变动由触发器留痕(customer_credit_history)。';
COMMENT ON COLUMN public.customers.credit_hold IS
    '人工冻结(SAL-B):无论敞口多少都停发 —— 客户在争议一张发票时停止发货不是算术条件。解除也是客户上的显式改动,同样留痕。';

-- GST-2:默认税码的【侧别】由触发器钉住 —— 销项码才挂得上客户。
-- 挂反了的码照样算得出数,却会进一个它根本不该进的格。
CREATE TRIGGER trg_customers_default_tax_code_side
    BEFORE INSERT OR UPDATE OF default_tax_code ON public.customers
    FOR EACH ROW EXECUTE FUNCTION public.guard_default_tax_code_side();

COMMENT ON COLUMN public.customers.default_tax_code IS
    'GST-2:开给这个客户的发票默认用哪个销项税码。**初值 NULL,而 NULL 不是一个默认值,是一个未回答的问题** —— 已注册时开票会按名拒(TAX_CODE_REQUIRED|customer),因为一个悄悄默认的税码是一个穿着默认值外衣的错答案。尤其不要按国别自动推 ZR:出口零税率在法定上取决于【出口证据】,不取决于账单地址,按国别推等于把一个证据问题答成一个地址问题。';

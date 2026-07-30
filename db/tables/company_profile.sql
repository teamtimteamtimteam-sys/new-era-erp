-- db/tables/company_profile.sql
-- 公司抬头档案 —— 单行表(同 finance_settings 的 id boolean PK 手法:
-- PRIMARY KEY DEFAULT true CHECK (id) 保证全表最多一行)。
--
-- 公司身份是【数据】不是代码:发票 PDF 上的名称、地址、联系方式、银行资料、页脚、
-- logo 全部从这里读,换个电话号码不需要发版。
--
-- 【GST 登记号不在本表】:cut 2a 已经把 gst_registration_no 放在 finance_settings
-- (与 gst_registered / gst_rate_pct 同族)。同一家公司只有一个 GST 登记号,存两份
-- 迟早不一致,且不一致时无从判断哪个对。发票 PDF 直接读 finance_settings 那一列。
--
-- logo_path 指向私有桶 'company-assets' 内的对象;PDF 生成时在服务端下载字节内嵌,
-- 不走签名 URL(渲染器内部不必再发一次网络请求)。
--
-- NOTE: introduced by db/migrations/2026-07-31-phase4-cut3-company-profile.sql.
-- First-run script (plain CREATEs). Run in the Supabase SQL Editor.

CREATE TABLE public.company_profile (
    id                  boolean PRIMARY KEY DEFAULT true CHECK (id),
    legal_name          text NOT NULL DEFAULT '',
    registration_no     text,
    address_lines       text,
    city                text,
    postal_code         text,
    country             text DEFAULT 'Singapore',
    phone               text,
    email               text,
    website             text,
    bank_name           text,
    bank_account_name   text,
    bank_account_no     text,
    bank_swift          text,
    bank_address        text,
    invoice_footer_text text,
    logo_path           text,
    updated_at          timestamptz NOT NULL DEFAULT now(),
    updated_by          uuid
);

CREATE TRIGGER trg_company_profile_updated_at
    BEFORE UPDATE ON public.company_profile
    FOR EACH ROW EXECUTE FUNCTION update_updated_at();

INSERT INTO public.company_profile (id, legal_name) VALUES (true, '');

ALTER TABLE public.company_profile ENABLE ROW LEVEL SECURITY;
CREATE POLICY "authenticated full access on company_profile"
    ON public.company_profile AS PERMISSIVE FOR ALL TO authenticated
    USING (true) WITH CHECK (true);

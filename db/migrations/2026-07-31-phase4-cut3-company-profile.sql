-- db/migrations/2026-07-31-phase4-cut3-company-profile.sql
-- Phase 4 cut 3:公司抬头档案(单行表)+ 私有桶 'company-assets'(放 logo)。
--
-- DESIGN:公司身份是【数据】不是代码 —— 换个电话号码不该需要发版。发票 PDF 的
-- 每一项(名称/地址/联系方式/银行资料/页脚/logo)都从这张表读,由 Tim 自己维护。
--
-- 【GST 登记号的去留 —— 决定:不再新增一列,复用 finance_settings.gst_registration_no】
-- cut 2a 已经在 finance_settings 上建了 gst_registration_no。这里【故意不建第二个】。
-- 理由:那是同一个现实事实 —— 一家公司只有一个 GST 登记号。把它存两份,迟早出现
-- 一处改了另一处没改,于是"打印在发票上的号"与"记账用的号"不一致;真出现不一致时,
-- 其中一个必然是错的,而系统无从判断哪个错。所谓"打印值 vs 记账值"的区分在这里
-- 是人为造出来的,没有任何业务场景需要它们不同。
-- 于是:GST 登记号继续住在 finance_settings(它与 gst_registered / gst_rate_pct 同族,
-- 本就是税务设置的一部分),发票 PDF 直接读那一列。company_profile 只管公司抬头本身。

BEGIN;

-- ============================================================================
-- 私有桶 company-assets(logo)。与 supplier-attachments / finance-attachments
-- 同一套做法:私有桶 + authenticated 的四条 storage.objects 策略;
-- 文件类型与大小限制在应用侧把关(与既有附件桶一致)。
-- ============================================================================
INSERT INTO storage.buckets (id, name, public)
VALUES ('company-assets', 'company-assets', false);

CREATE POLICY "authenticated read company-assets"
    ON storage.objects FOR SELECT TO authenticated
    USING (bucket_id = 'company-assets');

CREATE POLICY "authenticated upload company-assets"
    ON storage.objects FOR INSERT TO authenticated
    WITH CHECK (bucket_id = 'company-assets');

CREATE POLICY "authenticated update company-assets"
    ON storage.objects FOR UPDATE TO authenticated
    USING (bucket_id = 'company-assets');

CREATE POLICY "authenticated delete company-assets"
    ON storage.objects FOR DELETE TO authenticated
    USING (bucket_id = 'company-assets');

-- ============================================================================
-- company_profile —— 单行表(同 finance_settings 的 id boolean PK 手法)
-- ============================================================================
CREATE TABLE public.company_profile (
    id                  boolean PRIMARY KEY DEFAULT true CHECK (id),
    legal_name          text NOT NULL DEFAULT '',
    registration_no     text,
    -- 注意:GST 登记号【不在这里】—— 见文件头的决定,它住在 finance_settings。
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
    logo_path           text,  -- 私有桶 company-assets 内的路径
    updated_at          timestamptz NOT NULL DEFAULT now(),
    updated_by          uuid
);

CREATE TRIGGER trg_company_profile_updated_at
    BEFORE UPDATE ON public.company_profile
    FOR EACH ROW EXECUTE FUNCTION update_updated_at();

-- 种下唯一的那一行(空串起步,由设置页填写)
INSERT INTO public.company_profile (id, legal_name) VALUES (true, '');

ALTER TABLE public.company_profile ENABLE ROW LEVEL SECURITY;
CREATE POLICY "authenticated full access on company_profile"
    ON public.company_profile AS PERMISSIVE FOR ALL TO authenticated
    USING (true) WITH CHECK (true);

COMMIT;

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

-- ═══════════════════════════════════════════════════════════════════════════
-- 【运行期配置 / RUNTIME CONFIG —— 下面的种子是"全新安装的默认值",不是线上快照】
-- 界面上可以改(app/finance/company/actions.ts:60,以及 logo 的设置/清除)。
-- 所以【线上与本文件不一致是正常的,不是漂移】,check_mirrors.py 不把本表与线上比对。
-- 它只保证镜像这一套自己首尾相顾(本文件引用到的码/科目都存在于对应的种子里)。
-- ═══════════════════════════════════════════════════════════════════════════

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
CREATE POLICY "company_profile select by permission"
    ON public.company_profile
    AS PERMISSIVE FOR SELECT TO authenticated
    USING (true);

CREATE POLICY "company_profile insert by permission"
    ON public.company_profile
    AS PERMISSIVE FOR INSERT TO authenticated
    WITH CHECK (has_permission('module.finance.edit'::text));

CREATE POLICY "company_profile update by permission"
    ON public.company_profile
    AS PERMISSIVE FOR UPDATE TO authenticated
    USING (has_permission('module.finance.edit'::text)) WITH CHECK (has_permission('module.finance.edit'::text));

CREATE POLICY "company_profile delete by permission"
    ON public.company_profile
    AS PERMISSIVE FOR DELETE TO authenticated
    USING (has_permission('module.finance.edit'::text));

-- cut 3 银行明细遮蔽:收回原始银行列。表级 SELECT 蕴含所有列,
-- 所以先整表收回,再把非银行列逐列授回。银行列只能经 company_profile_masked 读取。
-- (check_mirrors 不比对 GRANT;这一段是为了让镜像仍能重建出权限状态。)
REVOKE SELECT ON public.company_profile FROM authenticated, anon;
GRANT SELECT (id, legal_name, registration_no, address_lines, city, postal_code, country,
              phone, email, website, invoice_footer_text, logo_path, updated_at, updated_by)
    ON public.company_profile TO authenticated;

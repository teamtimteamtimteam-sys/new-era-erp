-- db/tables/company_compliance.sql
-- 公司自己的执照与资质(CMP-1)。【空着是预期状态】—— 公司尚未运营,静默正确,
-- 故无空登记簿告警;录入提醒在 docs/fresh-install-checklist.md。第一张真执照进来
-- 不需要任何 schema 变更:号码、签发方、范围、有效期、文件都在。
-- SELECT 挂 module.suppliers.view 的理由在 docs/compliance-scoping.md §C。
-- NOTE: introduced by db/migrations/2026-08-09-cmp1-certificate-types-and-compliance-framework.sql.
-- First-run script (plain CREATEs). Run in the Supabase SQL Editor.

CREATE TABLE public.company_compliance (
    id             uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    cert_type_code text NOT NULL REFERENCES public.certificate_types (code),
    cert_no        text,
    issuing_body   text,
    -- 执照的适用范围(如"E 类有害废物贮存,上限 60 吨")—— 供应商表没有这一列,
    -- 公司执照有配额与类别,范围是它区别于"有没有"的那一半
    scope          text,
    valid_from     date,
    valid_until    date,
    -- company-assets 桶里的对象键(logo 同桶)。公司侧没有附件表,先用对象键;
    -- 若将来公司文件多到要管理,再建 company_attachments —— 那是加表,不动本表
    document_path  text,
    notes          text,
    deleted_at     timestamptz,
    created_at     timestamptz NOT NULL DEFAULT now(),
    created_by     uuid,
    updated_at     timestamptz NOT NULL DEFAULT now(),
    updated_by     uuid
);

CREATE INDEX idx_company_compliance_valid_until
    ON public.company_compliance (valid_until) WHERE deleted_at IS NULL;

CREATE TRIGGER trg_company_compliance_updated_at
    BEFORE UPDATE ON public.company_compliance
    FOR EACH ROW EXECUTE FUNCTION update_updated_at();

COMMENT ON TABLE public.company_compliance IS
    '公司自己的执照与资质(CMP-1)。空着是预期状态 —— 公司尚未运营,静默正确,故无空登记簿告警(录入提醒在 docs/fresh-install-checklist.md)。SELECT 挂 module.suppliers.view:合规没有自己的模块,而资质的读者与供应商资质是同一批人 —— 记录在 docs/compliance-scoping.md §C,将来建合规模块时这里是要改的那一行。';

ALTER TABLE public.company_compliance ENABLE ROW LEVEL SECURITY;
CREATE POLICY "company_compliance select by permission"
    ON public.company_compliance
    AS PERMISSIVE FOR SELECT TO authenticated
    USING (has_permission('module.suppliers.view'::text));
CREATE POLICY "company_compliance insert by permission"
    ON public.company_compliance
    AS PERMISSIVE FOR INSERT TO authenticated
    WITH CHECK (has_permission('module.suppliers.edit'::text));
CREATE POLICY "company_compliance update by permission"
    ON public.company_compliance
    AS PERMISSIVE FOR UPDATE TO authenticated
    USING (has_permission('module.suppliers.edit'::text))
    WITH CHECK (has_permission('module.suppliers.edit'::text));

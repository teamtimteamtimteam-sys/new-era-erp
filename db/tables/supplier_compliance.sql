-- db/tables/supplier_compliance.sql
-- 供应商资质/合规证书(环保许可、营业执照、ISO 等):一行一证。valid_until 用于
-- 到期提醒(部分索引只扫在册行)。document_id 存附件引用【无外键】—— 建表时附件
-- 体系尚未定型,保持线上原样。ON DELETE CASCADE:供应商(硬)删则证书随之。
-- updated_at 由共享 update_updated_at() 维护(注意触发器名是 trg_compliance_updated_at,
-- 策略名是 "authenticated full access on compliance" —— 建表早期的短命名,保持原样)。
--
-- NOTE: 本表早于"迁移 + 镜像"约定(建库初期直接在 Supabase SQL Editor 建的),
-- 一直没有镜像文件;2026-07-31 镜像漂移审计后【按线上目录重建】了本文件。
-- First-run script (plain CREATEs). Run in the Supabase SQL Editor.

CREATE TABLE public.supplier_compliance (
    id           uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    supplier_id  uuid NOT NULL REFERENCES public.suppliers (id) ON DELETE CASCADE,
    cert_type    text NOT NULL,
    cert_no      text,
    issuing_body text,
    valid_from   date,
    valid_until  date,
    document_id  uuid,
    notes        text,
    deleted_at   timestamptz,
    created_at   timestamptz NOT NULL DEFAULT now(),
    created_by   uuid REFERENCES auth.users (id),
    updated_at   timestamptz NOT NULL DEFAULT now(),
    updated_by   uuid REFERENCES auth.users (id)
);

CREATE INDEX idx_compliance_supplier ON public.supplier_compliance (supplier_id) WHERE deleted_at IS NULL;
CREATE INDEX idx_compliance_valid_until ON public.supplier_compliance (valid_until) WHERE deleted_at IS NULL;

CREATE TRIGGER trg_compliance_updated_at
    BEFORE UPDATE ON public.supplier_compliance
    FOR EACH ROW EXECUTE FUNCTION update_updated_at();

ALTER TABLE public.supplier_compliance ENABLE ROW LEVEL SECURITY;
CREATE POLICY "authenticated full access on compliance"
    ON public.supplier_compliance AS PERMISSIVE FOR ALL TO authenticated
    USING (true) WITH CHECK (true);

-- db/tables/suppliers.sql
-- 供应商主档。三样东西在这份文件里同住:
--   * supplier_status 枚举 + validate_supplier_status_transition —— 供应商是唯一
--     有【状态机】的主档(draft → pending_review → approved → active → …),
--     非法跳转在 BEFORE UPDATE 触发器里直接拒绝;
--   * code 'SUP-YYYY-NNNN' 由 BEFORE INSERT 触发器从序列取号(非无缝,主档无所谓);
--   * updated_at 由共享的 update_updated_at() 维护(定义在
--     db/functions/update_updated_at.sql,勿在此重复定义)。
-- created_by/updated_by/owner_id 直接外键到 auth.users —— 这是建库初期的写法,
-- 后来的表都不再挂 auth 外键(只存 uuid);保持线上原样,不"顺手统一"。
--
-- NOTE: 本表早于"迁移 + 镜像"约定(建库初期直接在 Supabase SQL Editor 建的),
-- 一直没有镜像文件;2026-07-31 镜像漂移审计后【按线上目录重建】了本文件。
-- default_payment_term_template_id 为
-- db/migrations/2026-07-31-phase4-cut4a-purchase-orders.sql 追加(列序按线上
-- attnum,追加列在末尾)。
-- First-run script (plain CREATEs). Run in the Supabase SQL Editor.

CREATE TYPE public.supplier_status AS ENUM (
    'draft', 'pending_review', 'approved', 'rejected',
    'active', 'suspended', 'blacklisted', 'archived'
);

CREATE SEQUENCE public.supplier_code_seq;

CREATE TABLE public.suppliers (
    id                               uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    code                             text NOT NULL UNIQUE,  -- 'SUP-YYYY-NNNN',触发器取号
    legal_name                       text NOT NULL,
    short_name                       text,
    country                          text NOT NULL,
    address                          text,
    tax_id                           text,
    supplier_types                   text[] NOT NULL DEFAULT '{}',
    payment_terms                    text,
    incoterm                         text,
    credit_rating                    text,
    status                           supplier_status NOT NULL DEFAULT 'draft',
    owner_id                         uuid REFERENCES auth.users (id),
    deleted_at                       timestamptz,
    notes                            text,
    created_at                       timestamptz NOT NULL DEFAULT now(),
    created_by                       uuid REFERENCES auth.users (id),
    updated_at                       timestamptz NOT NULL DEFAULT now(),
    updated_by                       uuid REFERENCES auth.users (id),
    default_payment_term_template_id uuid REFERENCES public.payment_term_templates (id)
);

CREATE INDEX idx_suppliers_code ON public.suppliers (code);
CREATE INDEX idx_suppliers_country ON public.suppliers (country) WHERE deleted_at IS NULL;
CREATE INDEX idx_suppliers_owner ON public.suppliers (owner_id) WHERE deleted_at IS NULL;
CREATE INDEX idx_suppliers_status ON public.suppliers (status) WHERE deleted_at IS NULL;

CREATE OR REPLACE FUNCTION public.generate_supplier_code()
RETURNS trigger LANGUAGE plpgsql AS $function$
BEGIN
  IF NEW.code IS NULL OR NEW.code = '' THEN
    NEW.code := 'SUP-' || EXTRACT(YEAR FROM NOW())::TEXT || '-' ||
                LPAD(nextval('supplier_code_seq')::TEXT, 4, '0');
  END IF;
  RETURN NEW;
END;
$function$;

CREATE OR REPLACE FUNCTION public.validate_supplier_status_transition()
RETURNS trigger LANGUAGE plpgsql AS $function$
BEGIN
  -- INSERT 时不检查
  IF TG_OP = 'INSERT' THEN
    RETURN NEW;
  END IF;

  -- 状态没变,不检查
  IF OLD.status = NEW.status THEN
    RETURN NEW;
  END IF;

  -- 定义合法跳转
  IF NOT (
    (OLD.status = 'draft'          AND NEW.status IN ('pending_review', 'archived')) OR
    (OLD.status = 'pending_review' AND NEW.status IN ('approved', 'rejected', 'draft')) OR
    (OLD.status = 'rejected'       AND NEW.status IN ('draft', 'archived')) OR
    (OLD.status = 'approved'       AND NEW.status IN ('active', 'suspended', 'archived')) OR
    (OLD.status = 'active'         AND NEW.status IN ('suspended', 'blacklisted', 'archived')) OR
    (OLD.status = 'suspended'      AND NEW.status IN ('active', 'blacklisted', 'archived')) OR
    (OLD.status = 'blacklisted'    AND NEW.status IN ('archived')) OR
    (OLD.status = 'archived'       AND NEW.status IN ('draft'))  -- 归档后可恢复为草稿
  ) THEN
    RAISE EXCEPTION '非法状态跳转: % → %', OLD.status, NEW.status;
  END IF;

  RETURN NEW;
END;
$function$;

CREATE TRIGGER trg_generate_supplier_code
    BEFORE INSERT ON public.suppliers
    FOR EACH ROW EXECUTE FUNCTION generate_supplier_code();

CREATE TRIGGER trg_suppliers_status_transition
    BEFORE UPDATE ON public.suppliers
    FOR EACH ROW EXECUTE FUNCTION validate_supplier_status_transition();

CREATE TRIGGER trg_suppliers_updated_at
    BEFORE UPDATE ON public.suppliers
    FOR EACH ROW EXECUTE FUNCTION update_updated_at();

ALTER TABLE public.suppliers ENABLE ROW LEVEL SECURITY;
CREATE POLICY "authenticated full access on suppliers"
    ON public.suppliers AS PERMISSIVE FOR ALL TO authenticated
    USING (true) WITH CHECK (true);

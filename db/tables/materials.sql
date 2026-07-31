-- db/tables/materials.sql
-- 物料主档。code 'MAT-YYYY-NNNN' 由 BEFORE INSERT 触发器从序列取号(非无缝,
-- 主档无审计连号要求)。软删除 deleted_at;status 自由文本。
-- 注意线上【没有】updated_at 触发器(建表早期漏挂,updated_at 靠应用层写)——
-- 镜像忠实于线上;要补触发器请走迁移,别只改这里。
--
-- NOTE: 本表早于"迁移 + 镜像"约定(建库初期直接在 Supabase SQL Editor 建的),
-- 一直没有镜像文件;2026-07-31 镜像漂移审计后【按线上目录重建】了本文件。
-- First-run script (plain CREATEs). Run in the Supabase SQL Editor.

CREATE SEQUENCE public.material_code_seq;

CREATE TABLE public.materials (
    id         uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    code       text NOT NULL UNIQUE,  -- 'MAT-YYYY-NNNN',触发器取号
    name       text NOT NULL,
    category   text NOT NULL,
    chemistry  text,
    unit       text NOT NULL DEFAULT 'kg',
    spec       text,
    notes      text,
    status     text NOT NULL DEFAULT 'draft',
    deleted_at timestamptz,
    created_at timestamptz NOT NULL DEFAULT now(),
    created_by uuid,
    updated_at timestamptz NOT NULL DEFAULT now(),
    updated_by uuid
);

CREATE OR REPLACE FUNCTION public.generate_material_code()
RETURNS trigger LANGUAGE plpgsql AS $function$
BEGIN
    IF NEW.code IS NULL OR NEW.code = '' THEN
        NEW.code := 'MAT-' || EXTRACT(YEAR FROM NOW())::TEXT || '-' ||
                    LPAD(nextval('material_code_seq')::TEXT, 4, '0');
    END IF;
    RETURN NEW;
END;
$function$;

CREATE TRIGGER trg_generate_material_code
    BEFORE INSERT ON public.materials
    FOR EACH ROW EXECUTE FUNCTION generate_material_code();

ALTER TABLE public.materials ENABLE ROW LEVEL SECURITY;
CREATE POLICY "authenticated full access on materials"
    ON public.materials AS PERMISSIVE FOR ALL TO authenticated
    USING (true) WITH CHECK (true);

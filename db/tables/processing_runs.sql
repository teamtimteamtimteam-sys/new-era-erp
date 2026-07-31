-- db/tables/processing_runs.sql
-- 加工批次(一次投料→产出的加工事件)。status 只有 committed/reversed 两态 ——
-- 加工一经提交只能整体冲销(rollback_processing_run),没有"编辑中"状态。
-- 成本列(material_cost_usd / process_cost_usd / total_cost_usd / allocation_*)
-- 由 allocate_processing_costs() 填写,allocation_snapshot 存分摊当刻的完整依据;
-- capitalized_cost_usd / capitalization_entry_id 是自动过账切次的产物(成本资本化
-- 分录)。code 'PROC-YYYY-NNNN' 触发器取号(非无缝)。
-- 无 updated_at 触发器(建表早期漏挂)—— 镜像忠实于线上。
--
-- NOTE: 本表早于"迁移 + 镜像"约定(建库初期直接在 Supabase SQL Editor 建的),
-- 一直没有镜像文件;2026-07-31 镜像漂移审计后【按线上目录重建】了本文件
-- (成本与资本化列是 phase1-cut2 / phase3-cut2a 等迁移陆续追加的,列序按线上 attnum)。
-- First-run script (plain CREATEs). Run in the Supabase SQL Editor.

CREATE SEQUENCE public.processing_code_seq;

CREATE TABLE public.processing_runs (
    id                      uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    code                    text NOT NULL UNIQUE,  -- 'PROC-YYYY-NNNN',触发器取号
    process_date            date,
    total_input             numeric,
    total_output            numeric,
    loss_qty                numeric,
    notes                   text,
    status                  text NOT NULL CHECK (status IN ('committed','reversed')),
    deleted_at              timestamptz,
    created_at              timestamptz NOT NULL DEFAULT now(),
    created_by              uuid,
    updated_at              timestamptz NOT NULL DEFAULT now(),
    updated_by              uuid,
    allocation_basis        text NOT NULL DEFAULT 'metal_value'
                            CHECK (allocation_basis IN ('weight','metal_value')),
    material_cost_usd       numeric,
    process_cost_usd        numeric,
    total_cost_usd          numeric,
    allocation_snapshot     jsonb,
    allocated_at            timestamptz,
    allocated_by            uuid,
    capitalized_cost_usd    numeric,
    capitalization_entry_id uuid REFERENCES public.journal_entries (id)
);

CREATE OR REPLACE FUNCTION public.generate_processing_code()
RETURNS trigger LANGUAGE plpgsql AS $function$
BEGIN
    IF NEW.code IS NULL OR NEW.code = '' THEN
        NEW.code := 'PROC-' || EXTRACT(YEAR FROM NOW())::TEXT || '-' ||
                    LPAD(nextval('processing_code_seq')::TEXT, 4, '0');
    END IF;
    RETURN NEW;
END;
$function$;

CREATE TRIGGER trg_generate_processing_code
    BEFORE INSERT ON public.processing_runs
    FOR EACH ROW EXECUTE FUNCTION generate_processing_code();

ALTER TABLE public.processing_runs ENABLE ROW LEVEL SECURITY;
CREATE POLICY "authenticated full access on processing_runs"
    ON public.processing_runs AS PERMISSIVE FOR ALL TO authenticated
    USING (true) WITH CHECK (true);

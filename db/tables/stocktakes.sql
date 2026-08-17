-- db/tables/stocktakes.sql
-- Stocktake headers — table + code-gen trigger + updated_at trigger + RLS.
-- Each stocktake collects counted quantities per batch (stocktake_lines) and is
-- posted via post_stocktake() (reconciles remaining_qty with adjustment movements).
-- Conventions match existing tables:
--   * code auto-generated 'ST-YYYY-NNNN' by a BEFORE INSERT trigger (dynamic year, 4-digit LPAD)
--   * soft delete via deleted_at
--   * audit fields created_by/updated_by default auth.uid(), created_at/updated_at default now()
--   * updated_at auto-bumped by the shared update_updated_at() function (do NOT redefine it)
--   * RLS: authenticated-only full access
--
-- NOTE: introduced by db/migrations/2026-07-03-phase2-cut4-stocktake.sql.
-- First-run script (plain CREATEs). Run in the Supabase SQL Editor.

CREATE SEQUENCE IF NOT EXISTS public.stocktake_code_seq;

CREATE OR REPLACE FUNCTION public.generate_stocktake_code()
RETURNS trigger LANGUAGE plpgsql AS $fn$
BEGIN
    IF NEW.code IS NULL OR NEW.code = '' THEN
        NEW.code := 'ST-' || EXTRACT(YEAR FROM NOW())::TEXT || '-' ||
                    LPAD(nextval('stocktake_code_seq')::TEXT, 4, '0');
    END IF;
    RETURN NEW;
END;
$fn$;

CREATE TABLE public.stocktakes (
    id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    code        text NOT NULL,
    status      text NOT NULL DEFAULT 'open' CHECK (status IN ('open','posted','cancelled')),
    notes       text,
    started_at  timestamptz NOT NULL DEFAULT now(),
    posted_at   timestamptz,
    deleted_at  timestamptz,
    created_by  uuid DEFAULT auth.uid(),
    updated_by  uuid DEFAULT auth.uid(),
    created_at  timestamptz NOT NULL DEFAULT now(),
    updated_at  timestamptz NOT NULL DEFAULT now(),
    -- ── AUDEL-1b 追加的列(ALTER 加的列排在末尾,与 attnum 顺序一致)──────
    deleted_by    uuid,
    delete_reason text,
    cancelled_at  timestamptz,
    cancelled_by  uuid,
    cancel_reason text
);

CREATE TRIGGER trg_generate_stocktake_code
    BEFORE INSERT ON public.stocktakes
    FOR EACH ROW EXECUTE FUNCTION public.generate_stocktake_code();

CREATE TRIGGER trg_stocktakes_updated_at
    BEFORE UPDATE ON public.stocktakes
    FOR EACH ROW EXECUTE FUNCTION update_updated_at();

ALTER TABLE public.stocktakes ENABLE ROW LEVEL SECURITY;
CREATE POLICY "stocktakes select by permission"
    ON public.stocktakes
    AS PERMISSIVE FOR SELECT TO authenticated
    USING (has_permission('module.stocktakes.view'::text));

CREATE POLICY "stocktakes insert by permission"
    ON public.stocktakes
    AS PERMISSIVE FOR INSERT TO authenticated
    WITH CHECK (has_permission('module.stocktakes.edit'::text));

CREATE POLICY "stocktakes update by permission"
    ON public.stocktakes
    AS PERMISSIVE FOR UPDATE TO authenticated
    USING (has_permission('module.stocktakes.edit'::text)) WITH CHECK (has_permission('module.stocktakes.edit'::text));

-- AUDEL-1a:硬删按名拒(STOCKTAKE_NO_HARD_DELETE|单号)。盘点单是【解释一次
-- 库存调整的那份单据】,而它的 adjustment 流水不可改 —— 单据没了、流水还在,
-- 台账说库存动过而没有任何东西说得出为什么,幸存的证据看起来还是完整的。
-- DELETE 策略【一并删掉】:PostgREST 把它暴露给任何持 module.stocktakes.edit 的人,
-- 而界面上根本没有这个按钮。两层,与流水那一族同形。
CREATE TRIGGER trg_stocktakes_no_hard_delete
    BEFORE DELETE ON public.stocktakes
    FOR EACH ROW EXECUTE FUNCTION public.guard_stocktake_no_hard_delete();

-- AUDEL-1b:置 deleted_at 必须走【门】(函数),且 deleted_by / delete_reason 必须填好。
-- 光加两列挡不住任何事 —— 软删本来就是一次直连 UPDATE。
CREATE TRIGGER trg_stocktakes_soft_delete_provenance
    BEFORE UPDATE ON public.stocktakes
    FOR EACH ROW EXECUTE FUNCTION public.guard_soft_delete_provenance();

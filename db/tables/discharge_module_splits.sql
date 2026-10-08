-- db/tables/discharge_module_splits.sql
-- MES-5a-1(2026-10-08,规格 §3.1 "re-discharge or quarantine, and both paths generate a record";MES-0 Q23;MES-5a Step 0 Q11,Tim):
--   【哪几个放电失败的模组被拆去隔离了,拆进了哪一批】—— 只追加,一个模组一行。
--   拆分本身是一张加工单(工序 discharge_quarantine_split,转化型:原批消耗拆出去的那几个模组称出来的重量,产出同一物料的一批,
--   带"带电未放电",放进隔离库位)—— 那张单记的是质量;这张表记的是【是哪几个模组】,那是加工单的腿记不下的。
--   一行 = 拆分那一炉(split_run_id)· 那个模组判失败的那一炉放电(discharge_run_id)· 原批(inbound_batch_id XOR output_batch_id)·
--   模组(module_ref)· 拆出来的那一批(new_output_batch_id)。
--   【当前】= 拆分那一炉没回滚 —— 回滚拆分那一炉,这几个模组就回到原批(核实跟着重算,discharge_verify_batch)。
--   核实时,拆出去的模组算"已处置",与当前的"通过"一起凑满原批的模组数(Q6)。
--   只经 split_failed_modules_to_quarantine(action.processing_aftercare;记那一炉还要 action.processing_commit)写;
--   UPDATE / DELETE / TRUNCATE 语句级拒。
--
-- NOTE: introduced by db/migrations/2026-10-08-mes5a1-discharge-by-module.sql.
-- First-run script (plain CREATEs).

CREATE TABLE public.discharge_module_splits (
    id                  bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    split_run_id        uuid NOT NULL REFERENCES public.processing_runs (id),
    discharge_run_id    uuid NOT NULL REFERENCES public.processing_runs (id),
    inbound_batch_id    uuid REFERENCES public.inbound_batches (id),
    output_batch_id     uuid REFERENCES public.output_batches (id),
    module_ref          text NOT NULL CHECK (btrim(module_ref) = module_ref AND module_ref <> '' AND length(module_ref) <= 60),
    new_output_batch_id uuid NOT NULL REFERENCES public.output_batches (id),
    created_at          timestamptz NOT NULL DEFAULT now(),
    created_by          uuid DEFAULT auth.uid(),
    CONSTRAINT discharge_module_splits_one_batch CHECK (num_nonnulls(inbound_batch_id, output_batch_id) = 1),
    CONSTRAINT discharge_module_splits_once_per_run UNIQUE (split_run_id, module_ref)
);

COMMENT ON TABLE public.discharge_module_splits IS
    'MES-5a-1:放电失败、处置为隔离的模组被拆去了哪一批(规格 §3.1 · MES-0 Q23)。拆分本身是一张 discharge_quarantine_split 加工单(记质量);这里记是哪几个模组。当前 = 拆分那一炉没回滚。核实时拆出去的模组算已处置。只经 split_failed_modules_to_quarantine 写。';

CREATE INDEX discharge_module_splits_inbound ON public.discharge_module_splits (inbound_batch_id);
CREATE INDEX discharge_module_splits_output ON public.discharge_module_splits (output_batch_id);

CREATE TRIGGER trg_discharge_module_splits_append_only
    BEFORE UPDATE OR DELETE OR TRUNCATE ON public.discharge_module_splits
    FOR EACH STATEMENT EXECUTE FUNCTION public.guard_append_only_log();

ALTER TABLE public.discharge_module_splits ENABLE ROW LEVEL SECURITY;
CREATE POLICY "discharge_module_splits select by permission" ON public.discharge_module_splits
    AS PERMISSIVE FOR SELECT TO authenticated
    USING (has_any_permission(ARRAY['module.processing.view'::text, 'module.inbound.view'::text, 'module.output.view'::text]));
GRANT SELECT ON public.discharge_module_splits TO authenticated;
REVOKE ALL ON public.discharge_module_splits FROM anon;

-- db/tables/discharge_channel_assignments.sql
-- MES-5a-1(2026-10-08,规格 §3.1 "the mapping between discharge channel number and module number";MES-0 Q9;MES-5a Step 0 Q9,Tim):
--   【一炉放电里,哪个通道接的是哪个模组】—— 只追加。装机时记:这一炉(run_id)、这一批(inbound_batch_id XOR output_batch_id)、
--   通道号、模组(module_ref,与 discharge_module_results 同一个批内标识)。
--   【当前】= 没被更正、没被撤回、那一炉没回滚。同一炉一个通道只有一条当前的;同一炉同一批一个模组也只有一条当前的
--   (record 函数判,不在这里建部分唯一索引 —— "当前"要看更正链,是一个读出来的判断)。
--   手工录入可以不记通道(录入时把模组与通道一起写在结果里);设备送来的结果只认通道号 —— 那一天,一个没记过的通道在收件箱里
--   【看得见地失败】(那条规矩跟着设备转换器一起建;MES-5a-1 没有建转换器,见 discharge_module_results 的抬头)。
--   一条结果带了通道号、而这一炉这个通道当前记着另一个模组 → DISCHARGE_CHANNEL_MODULE_MISMATCH(两份记录不许各说各话)。
--   【更正】新行指回原行(corrects_id 唯一)+ 必填理由;withdrawn = 撤回这一条(通道空出来)。
--   只经 assign_discharge_channel / correct_discharge_channel(action.processing_aftercare)写;UPDATE / DELETE / TRUNCATE 语句级拒。
--
-- NOTE: introduced by db/migrations/2026-10-08-mes5a1-discharge-by-module.sql.
-- First-run script (plain CREATEs).

CREATE TABLE public.discharge_channel_assignments (
    id                bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    run_id            uuid NOT NULL REFERENCES public.processing_runs (id),
    inbound_batch_id  uuid REFERENCES public.inbound_batches (id),
    output_batch_id   uuid REFERENCES public.output_batches (id),
    channel_no        integer NOT NULL CHECK (channel_no > 0),
    module_ref        text NOT NULL CHECK (btrim(module_ref) = module_ref AND module_ref <> '' AND length(module_ref) <= 60),
    withdrawn         boolean NOT NULL DEFAULT false,
    assigned_at       timestamptz NOT NULL DEFAULT now(),
    assigned_by       uuid DEFAULT auth.uid(),
    corrects_id       bigint UNIQUE REFERENCES public.discharge_channel_assignments (id),
    correction_reason text,
    CONSTRAINT discharge_channel_assignments_one_batch CHECK (num_nonnulls(inbound_batch_id, output_batch_id) = 1),
    CONSTRAINT discharge_channel_assignments_withdrawn_is_correction CHECK (NOT withdrawn OR corrects_id IS NOT NULL),
    CONSTRAINT discharge_channel_assignments_correction_shape
        CHECK ((corrects_id IS NULL) = (correction_reason IS NULL)
               AND (correction_reason IS NULL OR btrim(correction_reason) <> ''))
);

COMMENT ON TABLE public.discharge_channel_assignments IS
    'MES-5a-1:一炉放电的通道 → 模组(规格 §3.1),只追加。当前 = 没被更正、没被撤回、那一炉没回滚;同一炉一个通道、同一批一个模组各只有一条当前的。更正 = 新行(corrects_id + 理由),撤回 = 一条 withdrawn 的更正。手工录入可以不记;设备来的结果只认通道号(那条"没记的通道在收件箱里看得见地失败"跟着设备转换器一起建)。';

CREATE INDEX discharge_channel_assignments_run ON public.discharge_channel_assignments (run_id);

CREATE TRIGGER trg_discharge_channel_assignments_append_only
    BEFORE UPDATE OR DELETE OR TRUNCATE ON public.discharge_channel_assignments
    FOR EACH STATEMENT EXECUTE FUNCTION public.guard_append_only_log();

ALTER TABLE public.discharge_channel_assignments ENABLE ROW LEVEL SECURITY;
CREATE POLICY "discharge_channel_assignments select by permission" ON public.discharge_channel_assignments
    AS PERMISSIVE FOR SELECT TO authenticated
    USING (has_any_permission(ARRAY['module.processing.view'::text, 'module.inbound.view'::text, 'module.output.view'::text]));
GRANT SELECT ON public.discharge_channel_assignments TO authenticated;
REVOKE ALL ON public.discharge_channel_assignments FROM anon;

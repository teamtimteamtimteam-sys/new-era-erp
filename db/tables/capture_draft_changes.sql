-- db/tables/capture_draft_changes.sql
-- MES-2(2026-10-06,规格 §6.3;MES-0 §3.6 · Q12;MES-2 Step 0 Q9,Tim):【确认时改过的值】—— 原值、确认值、理由,一个字段一行。
--   规格 §6.3:"both the original and corrected values are retained and a reason for correction is required"。
--   confirm_capture_draft 只在确认值与 proposed 里那一格【不一样】时落一行;理由必填(CHECK + 函数里按名拒
--   CAPTURE_CHANGE_REASON_REQUIRED|<字段>)。能改的只有【量出来的值】(称重:weight_kg);设备、网关、序号、来源、现场时间
--   一个都改不了(CAPTURE_FIELD_FIXED|<字段>,MES-0 Q12)。主语(哪一张地磅单、毛重还是皮重)是确认时【选】的 ——
--   网关的 proposed 里没有它(Q7:payload 只有 weight_kg),所以选它不是"改",不落行。
--   只追加(guard_capture_append_only)。进变更记录。读:module.processing.view。
--
-- NOTE: introduced by db/migrations/2026-10-06-mes2-confirmation-weighing-calibration.sql.
-- First-run script (plain CREATEs).

CREATE TABLE public.capture_draft_changes (
    id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    draft_id        uuid NOT NULL REFERENCES public.capture_drafts (id),
    field           text NOT NULL CHECK (field ~ '^[a-z][a-z0-9_]*$'),
    original_value  jsonb,
    confirmed_value jsonb NOT NULL,
    reason          text NOT NULL CHECK (btrim(reason) <> ''),
    created_at      timestamptz NOT NULL DEFAULT now(),
    created_by      uuid DEFAULT auth.uid(),
    CONSTRAINT capture_draft_changes_one_per_field UNIQUE (draft_id, field),
    CONSTRAINT capture_draft_changes_really_changed CHECK (original_value IS DISTINCT FROM confirmed_value)
);

COMMENT ON TABLE public.capture_draft_changes IS
    'MES-2:确认时改过的值(规格 §6.3)—— 原值、确认值、必填理由,一个字段一行;只在两者不同时落。能改的只有量出来的值(weight_kg);设备、网关、序号、来源、现场时间改不了。只追加。';

CREATE TRIGGER trg_capture_draft_changes_append_only
    BEFORE UPDATE ON public.capture_draft_changes
    FOR EACH ROW EXECUTE FUNCTION public.guard_capture_append_only();
CREATE TRIGGER trg_capture_draft_changes_no_delete
    BEFORE DELETE OR TRUNCATE ON public.capture_draft_changes
    FOR EACH STATEMENT EXECUTE FUNCTION public.guard_capture_append_only();

ALTER TABLE public.capture_draft_changes ENABLE ROW LEVEL SECURITY;

CREATE POLICY "capture_draft_changes select by permission" ON public.capture_draft_changes
    AS PERMISSIVE FOR SELECT TO authenticated
    USING (has_permission('module.processing.view'::text));

REVOKE ALL ON public.capture_draft_changes FROM anon;

-- db/tables/contamination_checks.sql
-- MES-4b(2026-10-07,规格 §3.4;MES-0 Q52;MES-4b Step 0 Q21–Q26,Tim):【一次交叉污染抽检】—— 只追加,逐次记。
--   一行挂在一炉(run_id)与一条流(stream_code)上;班次从那一炉读(processing_runs.process_date · shift_code),【不另存】——
--   所以表头更正改了班次(correct_run_header),抽检跟着走。
--   两种:
--     sampled      抽了:样品质量与其中外来物的质量(克;外来物 ≤ 样品)、抽样时刻、方法(自由文本);抽的那一批是这一炉的一条
--                  【这条流的极片】产出腿(output_batch_id)。污染率 = 外来物 / 样品 × 100(生成列)。
--     not_sampled  这一班没抽 —— 必须写理由。它关掉这一班这条流的提醒,而"没抽"这件事留在记录里(Q23)。
--   警戒线(V11)在记录那一刻抄进 warning_pct_at;above_warning = 污染率 > 那条线(线为空时 NULL = 判不了,不是"在范围内")。
--   超过只标出来,从不拒(Q21)。与物料平衡无关:污染不改质量(规格 §3.4),结平不等它、也不读它。
--   【更正】新行指回原行(corrects_id 唯一)+ 必填理由;读链的末端。种类可以在更正时改(抽了 ↔ 没抽)。
--   只经 record_contamination_check / correct_contamination_check(action.processing_aftercare)写;UPDATE / DELETE / TRUNCATE 语句级拒。
--   读:加工或产出查看码(极片批买方关心的质量事实)—— 人读的那一份经 contamination_check_rows(带门的属主视图:
--   只持产出码的人读不到 processing_runs,一张 invoker 视图会安静地丢行 —— AGENTS.md 的 xmodule)。
--   不建取样仪器(Q26):样品天平不在设备登记里,校准闸仍只管称重。
--
-- NOTE: introduced by db/migrations/2026-10-07-mes4b-fields-and-products.sql.
-- First-run script (plain CREATEs).

CREATE TABLE public.contamination_checks (
    id                 bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    run_id             uuid NOT NULL REFERENCES public.processing_runs (id),
    stream_code        text NOT NULL REFERENCES public.contamination_streams (code),
    kind               text NOT NULL CHECK (kind IN ('sampled', 'not_sampled')),
    output_batch_id    uuid REFERENCES public.output_batches (id),
    sample_mass_g      numeric,
    foreign_mass_g     numeric,
    rate_pct           numeric GENERATED ALWAYS AS (
                           CASE WHEN kind = 'sampled' AND sample_mass_g > 0 THEN foreign_mass_g * 100 / sample_mass_g END) STORED,
    warning_pct_at     numeric,
    above_warning      boolean GENERATED ALWAYS AS (
                           CASE WHEN kind = 'sampled' AND sample_mass_g > 0 AND warning_pct_at IS NOT NULL
                                THEN foreign_mass_g * 100 / sample_mass_g > warning_pct_at END) STORED,
    sampled_at         timestamptz,
    method             text,
    not_sampled_reason text,
    recorded_at        timestamptz NOT NULL DEFAULT now(),
    recorded_by        uuid DEFAULT auth.uid(),
    corrects_id        bigint UNIQUE REFERENCES public.contamination_checks (id),
    correction_reason  text,
    CONSTRAINT contamination_checks_sampled_shape CHECK (
        kind <> 'sampled' OR (output_batch_id IS NOT NULL AND sample_mass_g > 0 AND foreign_mass_g >= 0
                              AND foreign_mass_g <= sample_mass_g AND sampled_at IS NOT NULL AND not_sampled_reason IS NULL)),
    CONSTRAINT contamination_checks_not_sampled_shape CHECK (
        kind <> 'not_sampled' OR (output_batch_id IS NULL AND sample_mass_g IS NULL AND foreign_mass_g IS NULL
                                  AND sampled_at IS NULL AND not_sampled_reason IS NOT NULL AND btrim(not_sampled_reason) <> '')),
    CONSTRAINT contamination_checks_correction_shape
        CHECK ((corrects_id IS NULL) = (correction_reason IS NULL)
               AND (correction_reason IS NULL OR btrim(correction_reason) <> ''))
);

COMMENT ON TABLE public.contamination_checks IS
    'MES-4b:交叉污染抽检,逐次、只追加(规格 §3.4)。sampled = 样品与外来物质量(克)、抽样时刻、方法,挂在这一炉这条流的一条极片产出腿上;not_sampled = 这一班没抽,带理由。污染率与"超过警戒线"是生成列;警戒线记录时抄下。班次读自那一炉。更正 = 新行(corrects_id + 理由);读链的末端。';

COMMENT ON COLUMN public.contamination_checks.above_warning IS
    'MES-4b(Q21 · V11):污染率是否高于记录那一刻的警戒线(warning_pct_at)。线为空 → NULL = 判不了,不是"在范围内"。只标出来,从不拒。';

CREATE INDEX contamination_checks_run ON public.contamination_checks (run_id);
CREATE INDEX contamination_checks_output_batch ON public.contamination_checks (output_batch_id);

CREATE TRIGGER trg_contamination_checks_append_only
    BEFORE UPDATE OR DELETE OR TRUNCATE ON public.contamination_checks
    FOR EACH STATEMENT EXECUTE FUNCTION public.guard_append_only_log();

ALTER TABLE public.contamination_checks ENABLE ROW LEVEL SECURITY;
CREATE POLICY "contamination_checks select by permission" ON public.contamination_checks
    AS PERMISSIVE FOR SELECT TO authenticated
    USING (has_any_permission(ARRAY['module.processing.view'::text, 'module.output.view'::text]));
GRANT SELECT ON public.contamination_checks TO authenticated;
REVOKE ALL ON public.contamination_checks FROM anon;

-- db/tables/discharge_module_results.sql
-- MES-5a-1(2026-10-08,规格 §3.1 · §9;MES-0 Q23–Q25;MES-5a Step 0 Q3–Q8 · Q12,Tim):【一个模组一次放电的结果】—— 只追加,逐次记。
--   一行挂在一炉深度放电(run_id,工序的 verifies_by_unit 为真)与那一炉的一批投料(inbound_batch_id XOR output_batch_id)上,
--   说的是那一批里的【一个模组】(module_ref:铭牌上读得出的序列号,读不出就写在模组上的位置标签,如 M01 —— 在这一批里唯一;
--   再放一次电沿用同一个)。通道号(channel_no)是另一格,可选。
--   必填:出口电压(伏)· 判定 pass | fail · 判定时刻 · 来源。判 fail 时【处置必填】re_discharge | quarantine(规格 §3.1:没有它,
--   一批里失败的模组在后面的记录里没有去处)。可选:起始电压 · 时长(分钟)· 回收能量(瓦时)· 一张屏幕照片(capture-photos 桶)·
--   设备、收件箱、草稿与现场数据指针(设备来的行)。
--   V9(materials.discharge_pass_voltage_v,按物料)在记录那一刻抄进 pass_voltage_v_at;contradicts_pass_voltage = 判通过而出口电压
--   高于它、或判失败而不高于它 —— 只标出来,从不拒,从不替人判;线为空 → NULL = 判不了。时长只记,不判。
--   【当前】= 没被更正(没有一行的 corrects_id 指着它)、所在的那一炉没回滚;【最新】= 同一批同一个模组的当前行里判定时刻最晚的那一条
--   (再按 id)—— 再放一次电时最新的赢。重放次数是推出来的(结果条数 − 1),不存。
--   【更正】新行指回原行(corrects_id 唯一)+ 必填理由;读链的末端。
--   【来源】今天只有 manual(MES-5a-1:Bosch 的逐模组导出格式没人给过,所以设备转换器【没有建】—— MES-3b Q25 · MES-4a Q14 的先例);
--   source / inbox_id / draft_id / site_* 这几列已经在,将来接上设备不必改表。
--   只经 record_discharge_module_result / correct_discharge_module_result(action.confirm_capture)写;UPDATE / DELETE / TRUNCATE 语句级拒。
--   读:加工、进料或产出查看码(批次页上要看得见自己那一批的逐模组结果)。
--
-- NOTE: introduced by db/migrations/2026-10-08-mes5a1-discharge-by-module.sql.
-- First-run script (plain CREATEs).

CREATE TABLE public.discharge_module_results (
    id                       bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    run_id                   uuid NOT NULL REFERENCES public.processing_runs (id),
    inbound_batch_id         uuid REFERENCES public.inbound_batches (id),
    output_batch_id          uuid REFERENCES public.output_batches (id),
    module_ref               text NOT NULL CHECK (btrim(module_ref) = module_ref AND module_ref <> '' AND length(module_ref) <= 60),
    channel_no               integer CHECK (channel_no IS NULL OR channel_no > 0),
    outlet_voltage_v         numeric NOT NULL CHECK (outlet_voltage_v >= 0),
    start_voltage_v          numeric CHECK (start_voltage_v IS NULL OR start_voltage_v >= 0),
    verdict                  text NOT NULL CHECK (verdict IN ('pass', 'fail')),
    verdict_at               timestamptz NOT NULL,
    disposition              text CHECK (disposition IN ('re_discharge', 'quarantine')),
    duration_min             numeric CHECK (duration_min IS NULL OR duration_min >= 0),
    energy_recovered_wh      numeric CHECK (energy_recovered_wh IS NULL OR energy_recovered_wh >= 0),
    pass_voltage_v_at        numeric,
    contradicts_pass_voltage boolean GENERATED ALWAYS AS (
                                 CASE WHEN pass_voltage_v_at IS NULL THEN NULL
                                      WHEN verdict = 'pass' THEN outlet_voltage_v > pass_voltage_v_at
                                      ELSE outlet_voltage_v <= pass_voltage_v_at END) STORED,
    photo_path               text,
    notes                    text,
    source                   text NOT NULL CHECK (source IN ('manual', 'device')),
    device_id                uuid REFERENCES public.devices (id),
    inbox_id                 bigint REFERENCES public.ingest_inbox (id),
    draft_id                 uuid REFERENCES public.capture_drafts (id),
    site_from                timestamptz,
    site_to                  timestamptz,
    site_dataset_ref         text,
    recorded_at              timestamptz NOT NULL DEFAULT now(),
    recorded_by              uuid DEFAULT auth.uid(),
    corrects_id              bigint UNIQUE REFERENCES public.discharge_module_results (id),
    correction_reason        text,
    CONSTRAINT discharge_module_results_one_batch CHECK (num_nonnulls(inbound_batch_id, output_batch_id) = 1),
    CONSTRAINT discharge_module_results_disposition_shape CHECK ((verdict = 'fail') = (disposition IS NOT NULL)),
    CONSTRAINT discharge_module_results_site_range CHECK (site_from IS NULL OR site_to IS NULL OR site_from <= site_to),
    CONSTRAINT discharge_module_results_correction_shape
        CHECK ((corrects_id IS NULL) = (correction_reason IS NULL)
               AND (correction_reason IS NULL OR btrim(correction_reason) <> ''))
);

COMMENT ON TABLE public.discharge_module_results IS
    'MES-5a-1:一个模组一次深度放电的结果,逐次、只追加(规格 §3.1)。一炉 × 一批 × 一个模组(module_ref,批内唯一,再放电沿用)。出口电压 · 判定 · 判定时刻必填;判失败时处置必填(再放电 / 隔离)。V9 抄进 pass_voltage_v_at,矛盾只标出不拒。最新的当前一条赢。更正 = 新行(corrects_id + 理由)。今天只有手工来源;设备那几列已在,设备转换器没有建(格式没人给过)。';

COMMENT ON COLUMN public.discharge_module_results.contradicts_pass_voltage IS
    'MES-5a-1(V9;Step 0 Q8):这一条判定是否与记录那一刻的通过电压(pass_voltage_v_at)矛盾 —— 判通过而出口电压高于它,或判失败而不高于它。线为空 → NULL = 判不了,不是"不矛盾"。只标出来,从不拒,从不替人判。';

-- 一炉一批一个模组只有一条原始行(其余是更正);再放电是另一炉
CREATE UNIQUE INDEX discharge_module_results_one_original
    ON public.discharge_module_results (run_id, COALESCE(inbound_batch_id, output_batch_id), module_ref)
    WHERE corrects_id IS NULL;
CREATE INDEX discharge_module_results_inbound ON public.discharge_module_results (inbound_batch_id);
CREATE INDEX discharge_module_results_output ON public.discharge_module_results (output_batch_id);

CREATE TRIGGER trg_discharge_module_results_append_only
    BEFORE UPDATE OR DELETE OR TRUNCATE ON public.discharge_module_results
    FOR EACH STATEMENT EXECUTE FUNCTION public.guard_append_only_log();

ALTER TABLE public.discharge_module_results ENABLE ROW LEVEL SECURITY;
CREATE POLICY "discharge_module_results select by permission" ON public.discharge_module_results
    AS PERMISSIVE FOR SELECT TO authenticated
    USING (has_any_permission(ARRAY['module.processing.view'::text, 'module.inbound.view'::text, 'module.output.view'::text]));
GRANT SELECT ON public.discharge_module_results TO authenticated;
REVOKE ALL ON public.discharge_module_results FROM anon;

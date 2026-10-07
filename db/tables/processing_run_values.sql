-- db/tables/processing_run_values.sql
-- MES-4a(2026-10-07,MES-0 Q43 · MES-4a Step 0 Q11 · Q12 · Q14 · Q29,Tim):【一炉记下的参数与指标】—— 只追加。
--   一行 = 这一炉的一个字段(operation_type_fields)的一个值;字段必须属于这一炉的工序(RUN_VALUE_FIELD_NOT_ON_OPERATION)。
--   值按字段的类型落在三列之一:value_number(number · count)· value_text(text)· value_bool(yes_no)。
--   【什么时候记】提交时(commit_processing_run 的 p_values,配方那一版先预填参数 —— source = 'recipe'),或之后在加工单页上
--   (record_run_value,action.processing_aftercare)。【必填在结平时判】(close_run_balance,Q11)—— 网关在批次结束时才送来的
--   指标,也能把一炉补完整。
--   【范围】记下的那一刻把字段的范围抄进来(range_min_at / range_max_at);越出它 → out_of_range 为真,【照记、标出来,不拒】(Q12)。
--   范围没给(Not yet set)→ out_of_range 是 NULL,不是 false —— "没法判"与"判过、在范围里"分得开。
--   【更正】一条新行:corrects_id 指回被更正的那一行、correction_reason 必填;每一行最多被更正一次(corrects_id 唯一),
--   读的人取链的末端(newest wins)。更正成"没有值"= 三列都空(撤回)。
--   【现场指针】source = 'device' 的行将来由网关的转换器写(MES-0 §3.9):inbox_id 与 site_from / site_to / site_dataset_ref。
--   本刀不建转换器(Q14);列先在这里,于是那一天不改这张表。
--   只经函数写;UPDATE / DELETE / TRUNCATE 语句级拒(APPEND_ONLY)。读:module.processing.view。
--
-- NOTE: introduced by db/migrations/2026-10-07-mes4a-processing-record.sql.
-- First-run script (plain CREATEs).

CREATE TABLE public.processing_run_values (
    id                  bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    run_id              uuid NOT NULL REFERENCES public.processing_runs (id),
    operation_type_code text NOT NULL,
    field_code          text NOT NULL,
    value_number        numeric,
    value_text          text,
    value_bool          boolean,
    range_min_at        numeric,
    range_max_at        numeric,
    out_of_range        boolean GENERATED ALWAYS AS (
                            CASE WHEN value_number IS NULL OR (range_min_at IS NULL AND range_max_at IS NULL) THEN NULL
                                 ELSE (value_number < range_min_at OR value_number > range_max_at) IS TRUE END) STORED,
    source              text NOT NULL CHECK (source IN ('manual', 'device', 'recipe')),
    inbox_id            bigint REFERENCES public.ingest_inbox (id),
    site_from           timestamptz,
    site_to             timestamptz,
    site_dataset_ref    text,
    recorded_at         timestamptz NOT NULL DEFAULT now(),
    recorded_by         uuid DEFAULT auth.uid(),
    corrects_id         bigint UNIQUE REFERENCES public.processing_run_values (id),
    correction_reason   text,
    FOREIGN KEY (operation_type_code, field_code) REFERENCES public.operation_type_fields (operation_type_code, field_code),
    CONSTRAINT processing_run_values_one_value
        CHECK (num_nonnulls(value_number, value_text, value_bool) = 1
               OR (num_nonnulls(value_number, value_text, value_bool) = 0 AND corrects_id IS NOT NULL)),
    CONSTRAINT processing_run_values_correction_shape
        CHECK ((corrects_id IS NULL) = (correction_reason IS NULL)
               AND (correction_reason IS NULL OR btrim(correction_reason) <> '')),
    CONSTRAINT processing_run_values_site_range
        CHECK (site_from IS NULL OR site_to IS NULL OR site_from <= site_to)
);

COMMENT ON TABLE public.processing_run_values IS
    'MES-4a:一炉记下的参数与指标,只追加。字段属于这一炉的工序;提交时或之后都能记;必填在结平时判。越出记下那一刻的范围 → out_of_range 为真(照记,不拒);范围没给 → NULL。更正 = 新行(corrects_id + 理由),读链的末端。source manual / device / recipe;device 行带现场指针(转换器以后建)。';

CREATE INDEX processing_run_values_run ON public.processing_run_values (run_id);
CREATE INDEX processing_run_values_field ON public.processing_run_values (operation_type_code, field_code);

CREATE TRIGGER trg_processing_run_values_append_only
    BEFORE UPDATE OR DELETE OR TRUNCATE ON public.processing_run_values
    FOR EACH STATEMENT EXECUTE FUNCTION public.guard_append_only_log();

ALTER TABLE public.processing_run_values ENABLE ROW LEVEL SECURITY;
CREATE POLICY "processing_run_values select by permission" ON public.processing_run_values
    AS PERMISSIVE FOR SELECT TO authenticated USING (has_permission('module.processing.view'::text));
GRANT SELECT ON public.processing_run_values TO authenticated;
REVOKE ALL ON public.processing_run_values FROM anon;

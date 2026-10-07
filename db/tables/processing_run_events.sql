-- db/tables/processing_run_events.sql
-- MES-4a(2026-10-07,规格 §3.1 · §5;MES-4a Step 0 Q15 · Q29,Tim):【一炉里的异常事件】—— 只追加,逐件记。
--   一行 = 一件:什么时候(occurred_at)、哪一种(processing_event_types)、多久(duration_min,可空 —— 一次报警可以没有时长)、
--   做了什么(action_taken)、谁负责(responsible_person)。规格 §3.1:"recorded individually, with time of occurrence, type, duration,
--   action taken and responsible person"。
--   【更正】新行指回原行(corrects_id 唯一)+ 必填理由;withdrawn = 这件事撤回(记错了一件不存在的事)。读链的末端。
--   【现场指针】source = 'device' 的行将来由网关的转换器写(workstation_event 类,本刀不建 —— Q14)。
--   只经 record_run_event / correct_run_event(action.processing_aftercare)写;UPDATE / DELETE / TRUNCATE 语句级拒。
--
-- NOTE: introduced by db/migrations/2026-10-07-mes4a-processing-record.sql.
-- First-run script (plain CREATEs).

CREATE TABLE public.processing_run_events (
    id                 bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    run_id             uuid NOT NULL REFERENCES public.processing_runs (id),
    event_type_code    text NOT NULL REFERENCES public.processing_event_types (code),
    occurred_at        timestamptz NOT NULL,
    duration_min       numeric CHECK (duration_min IS NULL OR duration_min >= 0),
    action_taken       text NOT NULL CHECK (btrim(action_taken) <> ''),
    responsible_person text NOT NULL CHECK (btrim(responsible_person) <> ''),
    notes              text,
    withdrawn          boolean NOT NULL DEFAULT false,
    source             text NOT NULL DEFAULT 'manual' CHECK (source IN ('manual', 'device')),
    inbox_id           bigint REFERENCES public.ingest_inbox (id),
    site_from          timestamptz,
    site_to            timestamptz,
    site_dataset_ref   text,
    recorded_at        timestamptz NOT NULL DEFAULT now(),
    recorded_by        uuid DEFAULT auth.uid(),
    corrects_id        bigint UNIQUE REFERENCES public.processing_run_events (id),
    correction_reason  text,
    CONSTRAINT processing_run_events_correction_shape
        CHECK ((corrects_id IS NULL) = (correction_reason IS NULL)
               AND (correction_reason IS NULL OR btrim(correction_reason) <> '')
               AND (NOT withdrawn OR corrects_id IS NOT NULL)),
    CONSTRAINT processing_run_events_site_range
        CHECK (site_from IS NULL OR site_to IS NULL OR site_from <= site_to)
);

COMMENT ON TABLE public.processing_run_events IS
    'MES-4a:一炉里的异常事件,逐件、只追加(规格 §3.1 · §5):时刻、种类、时长、处置、负责人。更正 = 新行(corrects_id + 理由),withdrawn = 撤回;读链的末端。';

CREATE INDEX processing_run_events_run ON public.processing_run_events (run_id);

CREATE TRIGGER trg_processing_run_events_append_only
    BEFORE UPDATE OR DELETE OR TRUNCATE ON public.processing_run_events
    FOR EACH STATEMENT EXECUTE FUNCTION public.guard_append_only_log();

ALTER TABLE public.processing_run_events ENABLE ROW LEVEL SECURITY;
CREATE POLICY "processing_run_events select by permission" ON public.processing_run_events
    AS PERMISSIVE FOR SELECT TO authenticated USING (has_permission('module.processing.view'::text));
GRANT SELECT ON public.processing_run_events TO authenticated;
REVOKE ALL ON public.processing_run_events FROM anon;

-- db/tables/sample_events.sql
-- MES-6a-1(2026-10-09,MES-6a Step 0 Q7 · Q15,Tim):【一份样品的保管记录 —— 只追加】。一行 = 一件发生过的事:
--   taken          取下来了(record_sample 自己写第一行;可以说放在哪个库位)
--   sent_to_lab    送去了哪一家实验室(laboratories,必填),带实验室那一侧的编号(可选)
--   received_back  从实验室拿回来了(可以说放在哪个库位)
--   moved          换了库位(库位必填)
--   disposed       处置掉了(理由必填)—— 之后这份样品不再有任何一行
--   【谁拿着、在哪、什么状态】都从【最近那一行】读(sample_rows),表上不另存一列状态 —— 一个事实一个地方(SETTLE-1 ② 那句
--   "还在不在"由一条记录回答,不由一个旗标回答)。
--   【先后】id 是 bigserial —— 同一笔事务里写的两行 created_at 相同,而 id 记得先后(AGENTS.md「取最新那一行」那一条);
--   occurred_at 不许早于上一行的 occurred_at(SAMPLE_EVENT_OUT_OF_ORDER),所以两种排法说的是同一个先后。
--   【顺序的规矩】拿在手上(taken / received_back / moved)才送得出去、挪得动、处置得了;在实验室时只能拿回来或处置(实验室毁样)。
--   【早于留样日的处置】允许,理由必填,并且被标出来(sample_rows.disposed_early,Q15)—— 一个没有合同天数撑着的日子不该挡人。
--   写只经 record_sample_event(与 record_sample 里的第一行)—— 表上一条写策略都没有;UPDATE / DELETE / TRUNCATE 一律语句级拒。
--
-- NOTE: introduced by db/migrations/2026-10-09-mes6a1-samples-and-disputes.sql.
-- First-run script (plain CREATEs).

CREATE TABLE public.sample_events (
    id                  bigserial PRIMARY KEY,
    sample_id           uuid NOT NULL REFERENCES public.samples (id),
    event_kind          text NOT NULL CHECK (event_kind IN ('taken', 'sent_to_lab', 'received_back', 'moved', 'disposed')),
    occurred_at         timestamptz NOT NULL,
    laboratory_code     text REFERENCES public.laboratories (code),
    lab_reference       text,
    storage_location_id uuid REFERENCES public.storage_locations (id),
    reason              text,
    notes               text,
    created_at          timestamptz NOT NULL DEFAULT now(),
    created_by          uuid DEFAULT auth.uid(),
    CONSTRAINT sample_events_lab_shape CHECK ((event_kind = 'sent_to_lab') = (laboratory_code IS NOT NULL)
                                              AND (lab_reference IS NULL OR event_kind = 'sent_to_lab')),
    CONSTRAINT sample_events_location_shape CHECK (
        (event_kind <> 'moved' OR storage_location_id IS NOT NULL)
        AND (storage_location_id IS NULL OR event_kind IN ('taken', 'received_back', 'moved'))),
    CONSTRAINT sample_events_disposal_reason CHECK (
        (event_kind = 'disposed') = (reason IS NOT NULL) AND (reason IS NULL OR btrim(reason) <> ''))
);

CREATE INDEX sample_events_sample_id_rel ON public.sample_events (sample_id, id);
CREATE INDEX sample_events_laboratory_code_rel ON public.sample_events (laboratory_code);
CREATE INDEX sample_events_storage_location_id_rel ON public.sample_events (storage_location_id);
-- 一份样品最多被处置一次
CREATE UNIQUE INDEX uq_sample_events_one_disposal ON public.sample_events (sample_id) WHERE event_kind = 'disposed';

COMMENT ON TABLE public.sample_events IS
    'MES-6a-1:一份样品的保管记录,只追加 —— taken · sent_to_lab(实验室必填)· received_back · moved(库位必填)· disposed(理由必填)。谁拿着、在哪、什么状态从最近一行读(sample_rows);id 记先后,occurred_at 不许倒退。写只经 record_sample / record_sample_event(module.quality.edit)。';
COMMENT ON COLUMN public.sample_events.occurred_at IS
    '这件事发生的时刻(人说的,可以早于记下来的时刻),不许早于这份样品上一行的时刻(SAMPLE_EVENT_OUT_OF_ORDER)—— 于是按 id 排与按它排是同一个先后。';

CREATE TRIGGER trg_sample_events_append_only
    BEFORE UPDATE OR DELETE OR TRUNCATE ON public.sample_events
    FOR EACH STATEMENT EXECUTE FUNCTION public.guard_append_only_log();

ALTER TABLE public.sample_events ENABLE ROW LEVEL SECURITY;
-- 读:与它那份样品同一句(质量查看码,或那一批自己那一页的查看码)。子查询把条件写全 —— trail_row_visible 在 DEFINER 里求值,
--   那里子查询不再过 samples 的 RLS(trail_row_visible 抬头那条已知边界)。写:一条策略都不给。
CREATE POLICY "sample_events select by permission" ON public.sample_events
    AS PERMISSIVE FOR SELECT TO authenticated
    USING (EXISTS (SELECT 1 FROM samples s WHERE s.id = sample_events.sample_id
                     AND (has_permission('module.quality.view'::text)
                          OR (s.inbound_batch_id IS NOT NULL AND has_permission('module.inbound.view'::text))
                          OR (s.output_batch_id IS NOT NULL AND has_permission('module.output.view'::text)))));
GRANT SELECT ON public.sample_events TO authenticated;
REVOKE ALL ON public.sample_events FROM anon;

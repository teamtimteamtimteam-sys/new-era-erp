-- db/tables/whistleblowing_updates.sql
-- ESG-2(Tim 2026-10-31 Q14):【一件举报之后的事】(只追加)—— 收到确认(acknowledged)· 调查中(investigating)· 结案(closed,带结论)。
--   一件举报现在的状态 = 它最后一行(id 是 identity,排得出先后);一行都没有 = 「已收到」(received)。结案之后不再追加。
--   【谁写】读得到那件举报的人(whistleblowing_report_update,同一个判据 whistleblowing_report_readable)。【谁读】同一批人;
--     交的人只经 my_concerns() 读到【状态与时刻】,读不到读者写的说明。不改、不删;不进变更记录(理由同 whistleblowing_reports)。
--
-- NOTE: introduced by db/migrations/2026-10-31-esg-2.sql.
-- First-run script (plain CREATEs).
CREATE TABLE public.whistleblowing_updates (
    id           bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    report_id    uuid NOT NULL REFERENCES public.whistleblowing_reports (id),
    status       text NOT NULL CHECK (status IN ('acknowledged', 'investigating', 'closed')),
    note         text NOT NULL CHECK (length(btrim(note)) BETWEEN 1 AND 10000),
    recorded_at  timestamptz NOT NULL DEFAULT now(),
    recorded_by  uuid NOT NULL
);
CREATE INDEX whistleblowing_updates_report_id_rel ON public.whistleblowing_updates (report_id, id);
COMMENT ON TABLE public.whistleblowing_updates IS
    'ESG-2(Q14):一件举报之后的状态(收到确认 · 调查中 · 结案,各带一句说明),只追加;最后一行是现在的状态,没有行 = 已收到。读与写都按那件举报自己的读码。不进变更记录。';
CREATE TRIGGER trg_whistleblowing_updates_immutable
    BEFORE UPDATE OR DELETE ON public.whistleblowing_updates
    FOR EACH STATEMENT EXECUTE FUNCTION public.guard_whistleblowing_write();
CREATE TRIGGER trg_whistleblowing_updates_truncate
    BEFORE TRUNCATE ON public.whistleblowing_updates
    FOR EACH STATEMENT EXECUTE FUNCTION public.guard_append_only_log();
ALTER TABLE public.whistleblowing_updates ENABLE ROW LEVEL SECURITY;
CREATE POLICY "whistleblowing_updates select by its report's reader code" ON public.whistleblowing_updates
    AS PERMISSIVE FOR SELECT TO authenticated
    USING (EXISTS (SELECT 1 FROM whistleblowing_reports r WHERE r.id = report_id AND whistleblowing_report_readable(r.concerns_cco)));
REVOKE ALL ON public.whistleblowing_updates FROM authenticated, anon;
GRANT SELECT ON public.whistleblowing_updates TO authenticated;

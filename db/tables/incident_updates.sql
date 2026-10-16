-- db/tables/incident_updates.sql
-- MES-7b-1(2026-10-16,MES-7b Step 0 Q3 · Q10,Tim):【一件事故之后发生的事实】—— 事故那一行写下就不改,以后的事一律是这里的一行(只追加)。
--   nea_notified      通报了 NEA:什么时候(必填、不在未来)、怎么通报的 / 编号(可选)。每件最多一行。
--                      有了它,incident_nea_notify_due 那条提醒就消失。
--   report_submitted  交了书面报告:什么时候(必填、不在未来)、报告编号(可选)。每件最多一行。有了它,incident_report_due 消失。
--   closed            关闭:一句总结(必填)。每件最多一行。关闭之后不再收更正(INCIDENT_CLOSED);NEA 的两件事实照常收 ——
--                      法定的义务不因为"关闭"而结束,两条提醒也不看关没关。
--   correction        一次带理由的更正:哪一个字段、新值(文本)、理由(必填)。可以更正的字段只有这七个:种类 · 发生时刻 · 发生了什么 ·
--                      当场做了什么 · 负责的人(名字)· 持续多久 · 要不要通报 NEA。库位、机器、两条引用与受伤的细节【不】在这里更正
--                      (库位与机器决定了批次的建议,引用是另一张表的行;受伤的细节是健康数据,写进一行不遮蔽的更正就是把它泄出去)。
--                      同一字段多次更正,最后一次(id 最大的那一行 —— identity 记录先后,不是 created_at)说了算。
--   【写】只经 record_incident_update(module.safety.edit)。会话里直连插入按名拒;改与删对谁都按名拒 INCIDENT_UPDATE_IMMUTABLE。
--   【读】module.safety.view。【没有遮蔽的列】—— 受伤的细节不经这里。
--
-- NOTE: introduced by db/migrations/2026-10-16-mes7b1-incidents.sql.
-- First-run script (plain CREATEs).

CREATE TABLE public.incident_updates (
    id          bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    incident_id uuid NOT NULL REFERENCES public.incidents (id),
    kind        text NOT NULL CHECK (kind IN ('nea_notified', 'report_submitted', 'closed', 'correction')),
    occurred_at timestamptz,
    reference   text,
    field       text CHECK (field IS NULL OR field IN ('kind_code', 'occurred_at', 'what_happened', 'immediate_action',
                                                      'responsible_name', 'duration_min', 'nea_reportable')),
    new_value   text,
    reason      text,
    summary     text,
    recorded_at timestamptz NOT NULL DEFAULT now(),
    recorded_by uuid DEFAULT auth.uid(),
    -- 每一种的形状:该有的有,不该有的没有
    CONSTRAINT incident_updates_shape CHECK (
        (kind IN ('nea_notified', 'report_submitted') AND occurred_at IS NOT NULL
            AND field IS NULL AND new_value IS NULL AND reason IS NULL AND summary IS NULL)
        OR (kind = 'closed' AND summary IS NOT NULL AND btrim(summary) <> ''
            AND occurred_at IS NULL AND reference IS NULL AND field IS NULL AND new_value IS NULL AND reason IS NULL)
        OR (kind = 'correction' AND field IS NOT NULL AND new_value IS NOT NULL AND reason IS NOT NULL AND btrim(reason) <> ''
            AND occurred_at IS NULL AND reference IS NULL AND summary IS NULL))
);

CREATE INDEX incident_updates_incident_id_rel ON public.incident_updates (incident_id);
-- 通报、交报告、关闭:每件最多一行(两个人同一刻记同一件事 —— 部分唯一索引是声明式的兜底)
CREATE UNIQUE INDEX incident_updates_one_fact ON public.incident_updates (incident_id, kind)
    WHERE kind IN ('nea_notified', 'report_submitted', 'closed');

COMMENT ON TABLE public.incident_updates IS
    'MES-7b-1:一件事故之后的事实(只追加):nea_notified(通报了 NEA)· report_submitted(交了书面报告)· closed(关闭,带总结)· correction(七个字段之一的更正,带理由;最后一次说了算)。写只经 record_incident_update(module.safety.edit)。';

ALTER TABLE public.incident_updates ENABLE ROW LEVEL SECURITY;
CREATE POLICY "incident_updates select by permission" ON public.incident_updates
    AS PERMISSIVE FOR SELECT TO authenticated
    USING (has_permission('module.safety.view'::text));
GRANT SELECT, INSERT, UPDATE, DELETE ON public.incident_updates TO authenticated;
REVOKE ALL ON public.incident_updates FROM anon;

-- 会话里直连插入按名拒(行级 BEFORE INSERT 先于 RLS 的 WITH CHECK);属主路径(record_incident_update)放行。
CREATE TRIGGER trg_incident_updates_direct
    BEFORE INSERT ON public.incident_updates
    FOR EACH ROW EXECUTE FUNCTION public.guard_incident_update_write();
-- 只可追加:改与删对谁都按名拒(语句级)。
CREATE TRIGGER trg_incident_updates_immutable
    BEFORE UPDATE OR DELETE ON public.incident_updates
    FOR EACH STATEMENT EXECUTE FUNCTION public.guard_incident_update_write();
CREATE TRIGGER trg_incident_updates_truncate
    BEFORE TRUNCATE ON public.incident_updates
    FOR EACH STATEMENT EXECUTE FUNCTION public.guard_append_only_log();

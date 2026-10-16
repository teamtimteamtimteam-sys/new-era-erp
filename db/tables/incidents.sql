-- db/tables/incidents.sql
-- MES-7b-1(2026-10-16,MES-0 功能 24 · Q53 · Q73 · Q76 · Q91;MES-7b Step 0 Q3 · Q5 · Q6 · Q9 · Q10 · Q27 · Q28,Tim):【一件事故】——
--   WSH 事故与未遂登记簿的一行(docs/forward-queue.md:2402 那条义务的载体):什么时候、哪一种、在哪、哪台机器、发生了什么、当场做了什么、
--   谁负责、要不要向 NEA 通报。
--
--   【编号】INC-YYYY-NNNN,按年、无洞(next_incident_code;document_types 的 'incident';宽度 GREATEST(4, 位数) —— CODE-WIDTH-4)。
--   【必填】种类 · 发生时刻(不在未来)· 发生了什么 · 当场做了什么 · 负责的人(一名员工,或写下名字)· 要不要通报 NEA(是 / 否,没有默认 ——
--     由记录的人对着那条义务回答,Q10:没有一条规矩替他判)。【可选】库位 · 机器(只认设备类资产)· 持续多久(分钟)。
--   【可选的引用】(Q9)一段停机(必须是同一台机器的、没作废的)· 一条加工单的异常事件(没撤回的)—— 引用,不是副本;两者谁都不取代谁:
--     可靠性(MTBF / MTTR)照旧只数停机,事故只进事故登记簿,同一件事不会被数两次。
--   【来源】manual · device。device【保留】(Q5):报警面板没有负载格式、也没有转换层(safety_alarm 那一类 transform_function 仍是空),
--     一行 device 按名拒(INCIDENT_SOURCE_RESERVED|device)—— equipment_downtime 的同一个先例。
--   【这一行写下就不改】(Q3)以后的事实是 incident_updates 的一行:通报了 NEA · 交了书面报告 · 关闭 · 一次带理由的更正。
--     页面上的"现在是什么样"由这一行加上那些更正算出来(incident_current_all)。
--   【受伤的细节】(Q6 · MES-0 Q76 · Q91)受伤的人(一名员工,或一个不是员工的人的名字)· 伤情 · 处理 · 误工天数 —— 健康数据:
--     从列授权里拿掉,只经 incidents_masked 读,给持 data.view_health 的人,并【对受伤的那名员工本人让路】
--     (change_log_mask_rules 的 code_or_self:data.view_health:injured_employee_id,三处同一个判据)。
--     任何持 module.safety.edit 的人都记得进去;记下之后,一个不持 data.view_health 的记录人看见的是「受限」。data.view_health 不授给 cto 与仓库。
--   【写】只经 SECURITY DEFINER 函数 record_incident(module.safety.edit,Q28)。会话里直连插入按名拒 INCIDENT_THROUGH_FUNCTION_ONLY;
--     改与删对谁都按名拒 INCIDENT_IMMUTABLE(语句级,所以 RLS 碰不到行时照样抛)。
--   【读】module.safety.view(基表的读策略);受伤的那名员工读自己那一件经 incidents_masked(那张视图的行谓词带本人)。
--   【没有金额】。
--
-- NOTE: introduced by db/migrations/2026-10-16-mes7b1-incidents.sql.
-- First-run script (plain CREATEs).

CREATE TABLE public.incidents (
    id                      uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    code                    text NOT NULL UNIQUE,
    kind_code               text NOT NULL REFERENCES public.incident_kinds (code),
    occurred_at             timestamptz NOT NULL,
    location_id             uuid REFERENCES public.storage_locations (id),
    equipment_id            uuid REFERENCES public.fixed_assets (id),
    duration_min            numeric CHECK (duration_min IS NULL OR duration_min >= 0),
    what_happened           text NOT NULL CHECK (btrim(what_happened) <> ''),
    immediate_action        text NOT NULL CHECK (btrim(immediate_action) <> ''),
    responsible_employee_id uuid REFERENCES public.employees (id),
    responsible_name        text,
    nea_reportable          boolean NOT NULL,
    source                  text NOT NULL DEFAULT 'manual' CHECK (source IN ('manual', 'device')),
    downtime_id             uuid REFERENCES public.equipment_downtime (id),
    run_event_id            bigint REFERENCES public.processing_run_events (id),
    injured_employee_id     uuid REFERENCES public.employees (id),
    injured_person_name     text,
    injury_nature           text,
    injury_treatment        text,
    days_lost               numeric CHECK (days_lost IS NULL OR days_lost >= 0),
    recorded_at             timestamptz NOT NULL DEFAULT now(),
    recorded_by             uuid DEFAULT auth.uid(),
    -- 负责的人:一名员工,或写下的一个名字(至少一样)
    CONSTRAINT incidents_responsible_named CHECK (
        responsible_employee_id IS NOT NULL OR (responsible_name IS NOT NULL AND btrim(responsible_name) <> '')),
    -- 受伤的人最多一个:一名员工,或一个不是员工的人的名字
    CONSTRAINT incidents_one_injured_person CHECK (num_nonnulls(injured_employee_id, injured_person_name) <= 1),
    -- 伤情、处理、误工天数要说的是某一个人
    CONSTRAINT incidents_injury_needs_person CHECK (
        (injury_nature IS NULL AND injury_treatment IS NULL AND days_lost IS NULL)
        OR num_nonnulls(injured_employee_id, injured_person_name) = 1),
    -- 引用一段停机就必须说出是哪台机器(同一台由 guard_incident_write 判)
    CONSTRAINT incidents_downtime_needs_machine CHECK (downtime_id IS NULL OR equipment_id IS NOT NULL)
);

CREATE INDEX incidents_kind_code_rel ON public.incidents (kind_code);
CREATE INDEX incidents_location_id_rel ON public.incidents (location_id);
CREATE INDEX incidents_equipment_id_rel ON public.incidents (equipment_id);
CREATE INDEX incidents_responsible_employee_id_rel ON public.incidents (responsible_employee_id);
CREATE INDEX incidents_downtime_id_rel ON public.incidents (downtime_id);
CREATE INDEX incidents_run_event_id_rel ON public.incidents (run_event_id);
CREATE INDEX incidents_injured_employee_id_rel ON public.incidents (injured_employee_id);
-- 搜索:code 的后缀匹配(与 nonconformance_reports 同一条)
CREATE INDEX incidents_code_trgm ON public.incidents USING gin (code extensions.gin_trgm_ops);

COMMENT ON TABLE public.incidents IS
    'MES-7b-1:一件事故(INC-YYYY-NNNN)—— 种类、时刻(不在未来)、可选的库位 / 机器 / 时长、发生了什么、当场做了什么、负责的人、要不要通报 NEA;可选地引用一段同一台机器的停机与一条异常事件。来源 manual(device 保留,按名拒)。写下就不改,以后的事实是 incident_updates 的行。受伤的人、伤情、处理、误工天数是健康数据:只经 incidents_masked 读(data.view_health 或受伤的那名员工本人)。写只经 record_incident(module.safety.edit)。';
COMMENT ON COLUMN public.incidents.nea_reportable IS
    '要不要向 NEA 通报 —— 记录的人对着那条义务回答(Q10),必填、没有默认。是:通报的提醒挂到记下通报为止;书面报告的期限 = 事故日之后第 V19 个工作日。';
COMMENT ON COLUMN public.incidents.source IS
    'manual(手工记)· device(保留 —— 报警面板没有负载格式,今天按名拒 INCIDENT_SOURCE_RESERVED)。';
COMMENT ON COLUMN public.incidents.downtime_id IS
    '可选:这件事故造成的那一段停机(同一台机器、没作废)。引用,不是副本 —— 可靠性照旧只数停机(Q9)。';
COMMENT ON COLUMN public.incidents.run_event_id IS
    '可选:加工单上的那一条异常事件(没撤回)。一条 safety_alarm 事件自己不开事故;两者谁都不取代谁(Q9)。';
COMMENT ON COLUMN public.incidents.injured_employee_id IS
    '健康数据(Q6):受伤的那名员工。只经 incidents_masked 读 —— data.view_health,或就是这名员工本人。';

ALTER TABLE public.incidents ENABLE ROW LEVEL SECURITY;
-- 读:安全查看码。写:一条策略都不给 —— 只经 record_incident。
CREATE POLICY "incidents select by permission" ON public.incidents
    AS PERMISSIVE FOR SELECT TO authenticated
    USING (has_permission('module.safety.view'::text));
-- ★ 健康数据(Q6):受伤的人、伤情、处理、误工天数从列授权里拿掉,只经 incidents_masked 读。
--   表级 SELECT 授权蕴含所有列,所以先整表收回、再逐列授回(medical_claims 的同一个做法)。
--   列授权不随 ADD COLUMN 自动延伸:给这张表加列,要回到这一行,并把它放进 incidents_masked(gate 的 colgrant)。
--   INSERT / UPDATE / DELETE 授着,是为了让直连的写走到下面那两支守卫、按名被拒,而不是撞上一句 42501。
REVOKE SELECT ON public.incidents FROM authenticated, anon;
GRANT SELECT (id, code, kind_code, occurred_at, location_id, equipment_id, duration_min, what_happened, immediate_action,
              responsible_employee_id, responsible_name, nea_reportable, source, downtime_id, run_event_id, recorded_at, recorded_by)
    ON public.incidents TO authenticated;
GRANT INSERT, UPDATE, DELETE ON public.incidents TO authenticated;
REVOKE ALL ON public.incidents FROM anon;

-- 插入:来源、时刻、种类、停机是不是同一台机器 —— 对每一个写入者都成立(属主路径也一样);会话里直连插入按名拒。
CREATE TRIGGER trg_incidents_insert
    BEFORE INSERT ON public.incidents
    FOR EACH ROW EXECUTE FUNCTION public.guard_incident_write();
-- 写下就不改:改与删对谁都按名拒 —— 语句级,所以 RLS 让一句 UPDATE 碰不到任何一行时它照样抛(ALERT-1)。
CREATE TRIGGER trg_incidents_immutable
    BEFORE UPDATE OR DELETE ON public.incidents
    FOR EACH STATEMENT EXECUTE FUNCTION public.guard_incident_write();
CREATE TRIGGER trg_incidents_truncate
    BEFORE TRUNCATE ON public.incidents
    FOR EACH STATEMENT EXECUTE FUNCTION public.guard_append_only_log();

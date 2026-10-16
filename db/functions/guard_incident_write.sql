-- db/functions/guard_incident_write.sql
-- MES-7b-1(2026-10-16,MES-7b Step 0 Q3 · Q5 · Q9,Tim):incidents 的守卫,一支函数两种挂法 ——
--   UPDATE / DELETE(语句级):对谁都按名拒 INCIDENT_IMMUTABLE|<动作> —— 一件事故写下就不改,以后的事实是 incident_updates 的一行。
--   INSERT(行级):
--     ① 会话里直连插入(row_security_active = 真)按名拒 INCIDENT_THROUGH_FUNCTION_ONLY;record_incident(属主路径)放行。
--     ② 下面这几条说的是【行】,所以对每一个写入者都成立(迁移、fixture、DEFINER 函数都一样):
--        来源只能是 manual(device 保留 —— INCIDENT_SOURCE_RESERVED|device,Q5)· 发生时刻不在未来(INCIDENT_TIME_IN_FUTURE|<时刻>)·
--        种类在清单里(INCIDENT_KIND_UNKNOWN|<代号>)而且启用着(INCIDENT_KIND_INACTIVE|<代号>)·
--        引用的停机是同一台机器的(INCIDENT_DOWNTIME_OTHER_MACHINE|<停机那台机器的编号>)、没作废(INCIDENT_DOWNTIME_VOIDED)·
--        引用的异常事件存在、没撤回、没被更正(INCIDENT_RUN_EVENT_NOT_FOUND / INCIDENT_RUN_EVENT_WITHDRAWN / INCIDENT_RUN_EVENT_CORRECTED|<更正那一行>)。
--   【为什么是 INVOKER】row_security_active 必须反映【调用者】的视角(guard_part_issue_write 同一个理由);① 在会话路径上第一个就抛,
--     所以后面那几句读表只在属主路径上跑。
-- NOTE: introduced by db/migrations/2026-10-16-mes7b1-incidents.sql.
CREATE OR REPLACE FUNCTION public.guard_incident_write()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_dt record;
    v_ev record;
BEGIN
    IF TG_LEVEL = 'STATEMENT' THEN
        RAISE EXCEPTION 'INCIDENT_IMMUTABLE|%', lower(TG_OP)
          USING HINT = '一件事故写下就不改。之后的事(通报了 NEA、交了书面报告、关闭、带理由的更正)在事故页上各记一行。';
    END IF;
    IF row_security_active(TG_RELID) THEN
        RAISE EXCEPTION 'INCIDENT_THROUGH_FUNCTION_ONLY';
    END IF;
    IF NEW.source IS DISTINCT FROM 'manual' THEN
        RAISE EXCEPTION 'INCIDENT_SOURCE_RESERVED|%', COALESCE(NEW.source, '?')
          USING HINT = '报警面板的事件格式还没有,所以今天每一件事故都是手工记的;device 这个来源留给它。';
    END IF;
    IF NEW.occurred_at > now() THEN
        RAISE EXCEPTION 'INCIDENT_TIME_IN_FUTURE|%', to_char(NEW.occurred_at AT TIME ZONE 'Asia/Singapore', 'YYYY-MM-DD HH24:MI');
    END IF;
    IF NOT EXISTS (SELECT 1 FROM incident_kinds k WHERE k.code = NEW.kind_code) THEN
        RAISE EXCEPTION 'INCIDENT_KIND_UNKNOWN|%', COALESCE(NEW.kind_code, '?');
    END IF;
    IF NOT EXISTS (SELECT 1 FROM incident_kinds k WHERE k.code = NEW.kind_code AND k.is_active) THEN
        RAISE EXCEPTION 'INCIDENT_KIND_INACTIVE|%', NEW.kind_code;
    END IF;
    IF NEW.downtime_id IS NOT NULL THEN
        SELECT d.equipment_id, d.voided_at, fa.code AS equipment_code INTO v_dt
          FROM equipment_downtime d JOIN fixed_assets fa ON fa.id = d.equipment_id
         WHERE d.id = NEW.downtime_id;
        IF NOT FOUND THEN
            RAISE EXCEPTION 'INCIDENT_DOWNTIME_NOT_FOUND|%', NEW.downtime_id;
        END IF;
        IF v_dt.equipment_id IS DISTINCT FROM NEW.equipment_id THEN
            RAISE EXCEPTION 'INCIDENT_DOWNTIME_OTHER_MACHINE|%', v_dt.equipment_code
              USING HINT = '一件事故只能引用它自己那台机器的停机 —— 另一台机器的停机说的是另一件事。';
        END IF;
        IF v_dt.voided_at IS NOT NULL THEN
            RAISE EXCEPTION 'INCIDENT_DOWNTIME_VOIDED';
        END IF;
    END IF;
    IF NEW.run_event_id IS NOT NULL THEN
        -- 一条事件的撤回与更正是【另一行】(corrects_id 指回它):引用的必须是那一条事件此刻说话的那一行
        SELECT e.withdrawn,
               (SELECT x.id FROM processing_run_events x WHERE x.corrects_id = e.id) AS superseded_by,
               COALESCE((SELECT x.withdrawn FROM processing_run_events x WHERE x.corrects_id = e.id), false) AS withdrawn_by
          INTO v_ev FROM processing_run_events e WHERE e.id = NEW.run_event_id;
        IF NOT FOUND THEN
            RAISE EXCEPTION 'INCIDENT_RUN_EVENT_NOT_FOUND|%', NEW.run_event_id;
        END IF;
        IF v_ev.withdrawn OR v_ev.withdrawn_by THEN
            RAISE EXCEPTION 'INCIDENT_RUN_EVENT_WITHDRAWN|%', NEW.run_event_id;
        END IF;
        IF v_ev.superseded_by IS NOT NULL THEN
            RAISE EXCEPTION 'INCIDENT_RUN_EVENT_CORRECTED|%', v_ev.superseded_by
              USING HINT = '这一条事件已经被更正过 —— 引用更正之后的那一行。';
        END IF;
    END IF;
    RETURN NEW;
END;
$function$;

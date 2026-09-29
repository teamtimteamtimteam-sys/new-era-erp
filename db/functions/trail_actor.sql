-- db/functions/trail_actor.sql
-- AUDIT-TRAIL-1a(Tim 的 Q14 · Q17 · Q18):"谁做的" —— 一份答法,两个读法共用。返回 {"state": …, "name": …}:
--   person     有一个人:称呼名,没有就用法定名(Q14;与 ActorName 同一个取法)。停用的账号照样印名字,不加任何字(Q17)。
--   anonymised 那个人已经被匿名化 —— 名字被抹掉是设计,界面说 "A former employee"。
--   system     没有登录会话的写:迁移、服务任务、fixture(Q17 · Q18,一律 "System (automatic)")。
--   removed    记下的是一个账号,而账号与人都已经不在了(Q17,"Removed account")。
--   unlinked   账号还在,但写入那一刻它不属于任何人(只有测试账号会这样)。
--   unknown    "记录开始之前"的那一段,当时那张表没有记人(p_kind = 'prelog' 且没有账号)—— 界面说 "Not recorded",不猜。
-- p_kind:change_log.actor_kind('user' / 'no_session'),或 'prelog'(从生命周期戳拼回来的行:只有账号,人按今天的链接认)。
-- 人名取自 employees(已被硬删的,取 change_log 里它最后一份影像)。【属主身份】EXECUTE 已从 authenticated 收回。
-- AUDIT-TRAIL-1b-1(Tim 2026-09-29 的折入 1,推翻 AT-1a 决定 1):
--   restricted 在系统别的页面上看到"受限"的读者,在审计记录里也看到 Restricted —— 与 ActorName 同一条规矩
--              (app/components/ActorName.tsx):不持 module.hr.view 的读者只认得出【他自己】;别人一律受限,
--              包括已匿名化的人与没有挂人的账号(那两种在 ActorName 里同样画成"受限")。
--              System (automatic)、Removed account、Not recorded 不是人名,照常说。
--   两个读法(每一页的 record_trail · /settings/change-history 的 change_log_rows)与引用值里的人(trail_ref_label)
--   都经过这里,所以一处改,处处同一个答案。
CREATE OR REPLACE FUNCTION public.trail_actor(p_kind text, p_account uuid, p_employee uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_emp  jsonb;
    v_id   uuid := p_employee;
    v_hide boolean := NOT has_permission('module.hr.view');
BEGIN
    IF p_kind = 'no_session' THEN
        RETURN jsonb_build_object('state', 'system');
    END IF;
    IF v_id IS NULL AND p_kind = 'prelog' AND p_account IS NOT NULL THEN
        v_id := account_person(p_account);
    END IF;
    IF v_id IS NULL THEN
        IF p_account IS NULL THEN
            RETURN jsonb_build_object('state', CASE WHEN p_kind = 'prelog' THEN 'unknown' ELSE 'removed' END);
        END IF;
        IF NOT EXISTS (SELECT 1 FROM auth.users u WHERE u.id = p_account) THEN
            RETURN jsonb_build_object('state', 'removed');
        END IF;
        RETURN jsonb_build_object('state', CASE WHEN v_hide THEN 'restricted' ELSE 'unlinked' END);
    END IF;
    IF v_hide AND v_id IS DISTINCT FROM current_user_employee() THEN
        RETURN jsonb_build_object('state', 'restricted');
    END IF;
    SELECT to_jsonb(e) INTO v_emp FROM employees e WHERE e.id = v_id;
    IF v_emp IS NULL THEN
        SELECT CASE WHEN c.op = 'DELETE' THEN c.old ELSE c.new END INTO v_emp
          FROM change_log c
         WHERE c.table_name = 'employees' AND c.row_key = jsonb_build_object('id', v_id) AND c.op IN ('INSERT', 'DELETE')
         ORDER BY c.seq DESC LIMIT 1;
    END IF;
    IF v_emp IS NULL THEN
        RETURN jsonb_build_object('state', 'removed');
    END IF;
    IF v_emp ->> 'anonymised_at' IS NOT NULL
       OR COALESCE(NULLIF(v_emp ->> 'preferred_name', ''), NULLIF(v_emp ->> 'legal_name', '')) IS NULL THEN
        RETURN jsonb_build_object('state', 'anonymised');
    END IF;
    RETURN jsonb_build_object('state', 'person',
        'name', COALESCE(NULLIF(v_emp ->> 'preferred_name', ''), v_emp ->> 'legal_name'));
END;
$function$;

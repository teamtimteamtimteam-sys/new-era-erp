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
CREATE OR REPLACE FUNCTION public.trail_actor(p_kind text, p_account uuid, p_employee uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_emp jsonb;
    v_id  uuid := p_employee;
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
        RETURN jsonb_build_object('state',
            CASE WHEN EXISTS (SELECT 1 FROM auth.users u WHERE u.id = p_account) THEN 'unlinked' ELSE 'removed' END);
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

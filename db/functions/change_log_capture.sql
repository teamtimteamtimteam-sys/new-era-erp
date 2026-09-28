-- db/functions/change_log_capture.sql
-- HISTORY-1:通用变更记录的【唯一】写入函数。238 张表各一条 AFTER ROW 触发器(zzz_change_log)
-- 与一条 AFTER TRUNCATE 语句触发器(zzz_change_log_truncate)调它;绑定清单在
-- db/views/zzz_change_log_triggers.sql(生成的,见 db/scripts/gen_change_log_bindings.py)。
--
-- 【函数体里没有一个列名】与 trg_fixed_assets_history 同一个做法(fixture 120 F5(d) 钉着):
--   一张表以后加了列,这里不用改,加的那一列自动进记录。
-- 【主键从触发器参数来】TG_ARGV 是主键列名 —— 生成绑定时从目录读一次,不在每一行上查。
-- 【actor】账号 = auth.uid();人 = account_person(账号),【此刻】冻住;没有会话 = 'no_session'。
-- 【db_role】★ 不能写 current_user:本函数是 SECURITY DEFINER,里面的 current_user 恒为属主。
--   `role` 设置记着 PostgREST 切过去的那个角色(authenticated / service_role),实测它穿得过
--   SECURITY DEFINER;没有切过(迁移、fixture 以超级用户跑)时它是 'none',回落 session_user。
-- 【SECURITY DEFINER 的理由】change_log 对任何应用角色都没有 INSERT 权限 —— 写只能以属主身份。
CREATE OR REPLACE FUNCTION public.change_log_capture()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_uid  uuid := auth.uid();
    v_role text := COALESCE(NULLIF(current_setting('role', true), 'none'), session_user::text);
    v_img  jsonb;
    v_old  jsonb;
    v_new  jsonb;
    v_cols text[];
    v_key  jsonb := '{}'::jsonb;
    i      integer;
BEGIN
    IF TG_LEVEL = 'STATEMENT' THEN
        -- TRUNCATE:一句话清空整张表,行级触发器不响。记下【发生过】;被清掉的行本身不在这里
        -- (docs/change-log.md 照直写着这一条限制)。
        INSERT INTO change_log (table_name, row_key, op, actor_account, actor_employee, actor_kind, db_role)
        VALUES (TG_TABLE_NAME, NULL, 'TRUNCATE', v_uid, account_person(v_uid),
                CASE WHEN v_uid IS NULL THEN 'no_session' ELSE 'user' END, v_role);
        RETURN NULL;
    END IF;

    IF TG_OP = 'INSERT' THEN
        v_img := to_jsonb(NEW);
        v_new := v_img;
    ELSIF TG_OP = 'DELETE' THEN
        v_img := to_jsonb(OLD);
        v_old := v_img;
    ELSE
        v_img := to_jsonb(NEW);
        v_old := to_jsonb(OLD);
        SELECT array_agg(n.key ORDER BY n.key) INTO v_cols
          FROM jsonb_each(v_img) n
         WHERE v_old -> n.key IS DISTINCT FROM n.value;
        IF v_cols IS NULL THEN
            RETURN NULL;          -- 改了等于没改:不写行
        END IF;
        SELECT jsonb_object_agg(k, v_old -> k), jsonb_object_agg(k, v_img -> k)
          INTO v_old, v_new
          FROM unnest(v_cols) k;
    END IF;

    FOR i IN 0 .. TG_NARGS - 1 LOOP
        v_key := v_key || jsonb_build_object(TG_ARGV[i], v_img -> TG_ARGV[i]);
    END LOOP;

    INSERT INTO change_log (table_name, row_key, op, actor_account, actor_employee, actor_kind,
                            db_role, changed_columns, old, new)
    VALUES (TG_TABLE_NAME, v_key, TG_OP, v_uid, account_person(v_uid),
            CASE WHEN v_uid IS NULL THEN 'no_session' ELSE 'user' END,
            v_role, v_cols, v_old, v_new);
    RETURN NULL;
END;
$function$;

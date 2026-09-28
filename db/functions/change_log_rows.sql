-- db/functions/change_log_rows.sql
-- HISTORY-1(Tim 的 Q10 · Q26 · Q6):变更记录的【唯一】读法。/settings/change-history 读它。
--
-- 【门】data.view_change_log(只授 admin 与 cfo,不捆进任何别的角色)。没有它 → PERMISSION_DENIED。
-- 【遮蔽】每一行按 change_log_mask_rules() 逐列问 change_log_rule_visible():读者在源屏幕上
--   看不见的值,这里换成 {"$restricted": true};本来就是 null 的留 null(见 change_log_restrict)。
-- 【任务隐私】任务四张表的记录先问 change_log_task_visible();不过 → 整份 old / new 换成受限标记,
--   只留时间、谁、表、主键、动作与改了哪几列的列名(row_restricted = true)。
-- 【筛选】日期(按库时区 Asia/Singapore,to 含当天)· 表 · 记录(主键里任一值等于它)·
--   人(账号 id 或员工 id 任一相等)· 只看无会话的写。
-- 【分页】按 seq 倒序,键集分页(p_before = 上一页最后一行的 seq),每页 1..200,默认 50。
-- 【SECURITY DEFINER 的理由】change_log 对应用角色没有任何授权;读 auth.users 取邮箱。
CREATE OR REPLACE FUNCTION public.change_log_rows(p_from date DEFAULT NULL::date, p_to date DEFAULT NULL::date, p_table text DEFAULT NULL::text, p_record text DEFAULT NULL::text, p_actor uuid DEFAULT NULL::uuid, p_no_session boolean DEFAULT false, p_before bigint DEFAULT NULL::bigint, p_limit integer DEFAULT 50)
 RETURNS TABLE(seq bigint, occurred_at timestamp with time zone, table_name text, row_key jsonb, op text, actor_account uuid, actor_email text, actor_employee uuid, actor_employee_code text, actor_employee_name text, actor_kind text, db_role text, changed_columns text[], old jsonb, new jsonb, redacted_at timestamp with time zone, row_restricted boolean)
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
#variable_conflict use_column
DECLARE
    r        record;
    m        record;
    v_hidden text[];
    v_limit  integer := LEAST(GREATEST(COALESCE(p_limit, 50), 1), 200);
BEGIN
    PERFORM require_permission('data.view_change_log');

    FOR r IN
        SELECT c.seq AS c_seq, c.occurred_at AS c_at, c.table_name AS c_table, c.row_key AS c_key,
               c.op AS c_op, c.actor_account AS c_account, u.email::text AS c_email,
               c.actor_employee AS c_employee, e.code AS c_emp_code,
               COALESCE(e.preferred_name, e.legal_name) AS c_emp_name,
               c.actor_kind AS c_kind, c.db_role AS c_role, c.changed_columns AS c_cols,
               c.old AS c_old, c.new AS c_new, c.redacted_at AS c_redacted
          FROM change_log c
          LEFT JOIN auth.users u ON u.id = c.actor_account
          LEFT JOIN employees e ON e.id = c.actor_employee
         WHERE (p_from IS NULL OR c.occurred_at >= p_from::timestamptz)
           AND (p_to IS NULL OR c.occurred_at < (p_to + 1)::timestamptz)
           AND (p_table IS NULL OR c.table_name = p_table)
           AND (p_record IS NULL OR EXISTS (SELECT 1 FROM jsonb_each_text(c.row_key) k WHERE k.value = p_record))
           AND (p_actor IS NULL OR c.actor_account = p_actor OR c.actor_employee = p_actor)
           AND (NOT COALESCE(p_no_session, false) OR c.actor_kind = 'no_session')
           AND (p_before IS NULL OR c.seq < p_before)
         ORDER BY c.seq DESC
         LIMIT v_limit
    LOOP
        seq := r.c_seq;
        occurred_at := r.c_at;
        table_name := r.c_table;
        row_key := r.c_key;
        op := r.c_op;
        actor_account := r.c_account;
        actor_email := r.c_email;
        actor_employee := r.c_employee;
        actor_employee_code := r.c_emp_code;
        actor_employee_name := r.c_emp_name;
        actor_kind := r.c_kind;
        db_role := r.c_role;
        changed_columns := r.c_cols;
        redacted_at := r.c_redacted;
        old := r.c_old;
        new := r.c_new;
        row_restricted := false;

        IF r.c_table IN ('tasks', 'task_nodes', 'task_participants', 'task_history')
           AND NOT change_log_task_visible(r.c_table, r.c_key, r.c_old, r.c_new) THEN
            old := change_log_restrict(r.c_old, NULL);
            new := change_log_restrict(r.c_new, NULL);
            row_restricted := true;
        ELSE
            v_hidden := ARRAY[]::text[];
            FOR m IN SELECT mr.column_name AS m_col, mr.rule AS m_rule
                       FROM change_log_mask_rules() mr WHERE mr.table_name = r.c_table LOOP
                IF (COALESCE(r.c_old -> m.m_col, 'null'::jsonb) <> 'null'::jsonb
                    OR COALESCE(r.c_new -> m.m_col, 'null'::jsonb) <> 'null'::jsonb)
                   AND NOT change_log_rule_visible(m.m_rule, r.c_table, r.c_key, r.c_old, r.c_new) THEN
                    v_hidden := v_hidden || m.m_col;
                END IF;
            END LOOP;
            IF cardinality(v_hidden) > 0 THEN
                old := change_log_restrict(r.c_old, v_hidden);
                new := change_log_restrict(r.c_new, v_hidden);
            END IF;
        END IF;
        RETURN NEXT;
    END LOOP;
END;
$function$;

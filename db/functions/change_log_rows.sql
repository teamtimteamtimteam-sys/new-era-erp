-- db/functions/change_log_rows.sql
-- HISTORY-1(Tim 的 Q10 · Q26 · Q6):变更记录的【唯一】全局读法。/settings/change-history 读它。
-- AUDIT-TRAIL-1a(Tim 的 Q5 · Q30 · Q31 · Q40):仍是这一支、仍是这一道门;加了读法,没有放宽。
--
-- 【门】data.view_change_log(只授 admin 与 cfo,不捆进任何别的角色)。没有它 → PERMISSION_DENIED。
-- 【遮蔽】逐行走 change_log_mask_row —— 与每一页底部的审计记录(record_trail)【同一步】(Q5),规则仍是
--   HISTORY-1 的 change_log_mask_rules():读者在源屏幕上看不见的值换成 {"$restricted": true},本来就是 null 的留 null;
--   任务四张表先问 change_log_task_visible(),不过 → 整份影像受限(row_restricted = true)。
-- 【筛选】日期(按库时区 Asia/Singapore,to 含当天)· 表(p_table 一张,或 p_tables 一组 —— "Area"与"Record type")·
--   记录(p_record:主键里任一值等于它;p_record_ids:主键里任一值在这一组里 —— 按单据号或名字找到的,见
--   change_log_find_records)· 人(账号 id 或员工 id 任一相等)· 只看无会话的写 · 只看"Removed account"的写。
-- 【分页】按 seq 倒序,键集分页(p_before)。p_by_entry = false:每页 p_limit 行(HISTORY-1 的原样);
--   p_by_entry = true:每页 p_limit 笔【事务】(一次操作一条,Q2),返回这些事务里符合筛选的全部行,
--   p_before 比的是一笔事务里最大的 seq。
-- 【每一行多带回】txid · actor(trail_actor:人名 / System (automatic) / Removed account …)·
--   belongs_to(trail_row_record:这一行属于哪张单据 / 哪条记录)· refs(trail_refs:每个引用值 → 名字)。
--   任务隐私受限的行不带 belongs_to 与 refs —— 任务标题本身就是被藏起来的东西。
-- 【它仍然列出每一次写入】(Q31):系统的、冒烟的、账号事件的,一行不少。
-- AUDIT-TRAIL-1d-1(Tim 2026-10-04,AT-1d Step 0 的 Q13):【每一行再过一次它自己那张表的读规则】—— 与每一页底部的审计记录
--   (record_trail 的第三道)同一个判法、同一支函数(trail_row_visible,对这一行今天的样子;已经删掉的,对它最后的影像)。
--   过不了 → 整份影像受限(row_restricted = true,与任务隐私同一个形状:界面说这一类记录被改过、内容受限)。
--   为什么:这一页的门是 data.view_change_log;以前只按 HISTORY-1 的列规则遮,而几张表是按【行】管的 ——
--   调薪申请要 hr.view 加 data.view_pay,评审与 KPI 要 data.view_reviews,账号事件要 manage_permissions。
--   一个持 view_change_log 而没有 view_pay 的人,以前在这里读得到每一笔调薪的金额。今天持这个码的两个人(admin、cfo)
--   两样都有,所以那时没有人读到 —— 它是一个躺着的洞,不是一次泄漏。同一行在同一次调用里只判一次(v_vis_cache)。
-- 【SECURITY DEFINER 的理由】change_log 对应用角色没有任何授权;读 auth.users 取邮箱与账号是否还在。
CREATE OR REPLACE FUNCTION public.change_log_rows(p_from date DEFAULT NULL::date, p_to date DEFAULT NULL::date, p_table text DEFAULT NULL::text, p_record text DEFAULT NULL::text, p_actor uuid DEFAULT NULL::uuid, p_no_session boolean DEFAULT false, p_before bigint DEFAULT NULL::bigint, p_limit integer DEFAULT 50, p_tables text[] DEFAULT NULL::text[], p_removed_account boolean DEFAULT false, p_by_entry boolean DEFAULT false, p_record_ids text[] DEFAULT NULL::text[])
 RETURNS TABLE(seq bigint, occurred_at timestamp with time zone, table_name text, row_key jsonb, op text, actor_account uuid, actor_email text, actor_employee uuid, actor_employee_code text, actor_employee_name text, actor_kind text, db_role text, changed_columns text[], old jsonb, new jsonb, redacted_at timestamp with time zone, row_restricted boolean, txid bigint, actor jsonb, belongs_to jsonb, refs jsonb)
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
#variable_conflict use_column
DECLARE
    r        record;
    v_mask   jsonb;
    v_limit  integer := LEAST(GREATEST(COALESCE(p_limit, 50), 1), 200);
    v_txids  bigint[];
    v_vkey   text;
    v_vis    boolean;
    v_cache  jsonb := '{}'::jsonb;
    v_cimg   record;
BEGIN
    PERFORM require_permission('data.view_change_log');

    IF COALESCE(p_by_entry, false) THEN
        SELECT array_agg(g.g_tx ORDER BY g.g_mx DESC) INTO v_txids FROM (
            SELECT c.txid AS g_tx, max(c.seq) AS g_mx
              FROM change_log c
             WHERE (p_from IS NULL OR c.occurred_at >= p_from::timestamptz)
               AND (p_to IS NULL OR c.occurred_at < (p_to + 1)::timestamptz)
               AND (p_table IS NULL OR c.table_name = p_table)
               AND (p_tables IS NULL OR c.table_name = ANY (p_tables))
               AND (p_record IS NULL OR EXISTS (SELECT 1 FROM jsonb_each_text(c.row_key) k WHERE k.value = p_record))
               AND (p_record_ids IS NULL OR EXISTS (SELECT 1 FROM jsonb_each_text(c.row_key) k WHERE k.value = ANY (p_record_ids)))
               AND (p_actor IS NULL OR c.actor_account = p_actor OR c.actor_employee = p_actor)
               AND (NOT COALESCE(p_no_session, false) OR c.actor_kind = 'no_session')
               AND (NOT COALESCE(p_removed_account, false)
                    OR (c.actor_kind = 'user' AND c.actor_employee IS NULL
                        AND NOT EXISTS (SELECT 1 FROM auth.users u2 WHERE u2.id = c.actor_account)))
             GROUP BY c.txid
            HAVING p_before IS NULL OR max(c.seq) < p_before
             ORDER BY max(c.seq) DESC
             LIMIT v_limit) g;
        IF v_txids IS NULL THEN
            RETURN;
        END IF;
    END IF;

    FOR r IN
        SELECT c.seq AS c_seq, c.occurred_at AS c_at, c.table_name AS c_table, c.row_key AS c_key,
               c.op AS c_op, c.actor_account AS c_account, u.email::text AS c_email,
               c.actor_employee AS c_employee, e.code AS c_emp_code,
               COALESCE(e.preferred_name, e.legal_name) AS c_emp_name,
               c.actor_kind AS c_kind, c.db_role AS c_role, c.changed_columns AS c_cols,
               c.old AS c_old, c.new AS c_new, c.redacted_at AS c_redacted, c.txid AS c_tx
          FROM change_log c
          LEFT JOIN auth.users u ON u.id = c.actor_account
          LEFT JOIN employees e ON e.id = c.actor_employee
         WHERE (p_from IS NULL OR c.occurred_at >= p_from::timestamptz)
           AND (p_to IS NULL OR c.occurred_at < (p_to + 1)::timestamptz)
           AND (p_table IS NULL OR c.table_name = p_table)
           AND (p_tables IS NULL OR c.table_name = ANY (p_tables))
           AND (p_record IS NULL OR EXISTS (SELECT 1 FROM jsonb_each_text(c.row_key) k WHERE k.value = p_record))
           AND (p_record_ids IS NULL OR EXISTS (SELECT 1 FROM jsonb_each_text(c.row_key) k WHERE k.value = ANY (p_record_ids)))
           AND (p_actor IS NULL OR c.actor_account = p_actor OR c.actor_employee = p_actor)
           AND (NOT COALESCE(p_no_session, false) OR c.actor_kind = 'no_session')
           AND (NOT COALESCE(p_removed_account, false)
                OR (c.actor_kind = 'user' AND c.actor_employee IS NULL AND u.id IS NULL))
           AND (CASE WHEN COALESCE(p_by_entry, false) THEN c.txid = ANY (v_txids)
                     ELSE (p_before IS NULL OR c.seq < p_before) END)
         ORDER BY c.seq DESC
         LIMIT CASE WHEN COALESCE(p_by_entry, false) THEN NULL ELSE v_limit END
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
        txid := r.c_tx;
        actor := trail_actor(r.c_kind, r.c_account, r.c_employee);

        v_mask := change_log_mask_row(r.c_table, r.c_key, r.c_old, r.c_new);
        old := NULLIF(v_mask -> 'old', 'null'::jsonb);
        new := NULLIF(v_mask -> 'new', 'null'::jsonb);
        row_restricted := (v_mask ->> 'row_restricted')::boolean;
        -- Q13:这一行过不过它自己那张表的读规则(每一行只判一次)
        v_vkey := r.c_table || '|' || COALESCE(r.c_key::text, '');
        IF v_cache ? v_vkey THEN
            v_vis := (v_cache ->> v_vkey)::boolean;
        ELSE
            SELECT * INTO v_cimg FROM trail_current_image(r.c_table, r.c_key);
            v_vis := COALESCE(trail_row_visible(r.c_table, r.c_key, COALESCE(v_cimg.image, r.c_new, r.c_old)), false);
            v_cache := v_cache || jsonb_build_object(v_vkey, v_vis);
        END IF;
        IF NOT v_vis AND NOT row_restricted THEN
            old := change_log_restrict(r.c_old, NULL);
            new := change_log_restrict(r.c_new, NULL);
            row_restricted := true;
        END IF;
        IF row_restricted OR r.c_table = 'auth.users' THEN
            belongs_to := NULL;
            refs := '{}'::jsonb;
        ELSE
            belongs_to := trail_row_record(r.c_table, r.c_key, old, new);
            refs := trail_refs(r.c_table, old, new, r.c_key);
        END IF;
        RETURN NEXT;
    END LOOP;
END;
$function$;

-- db/functions/change_log_page.sql
-- GOLIVE-2(第 13 行,Tim 2026-10-24 · 2026-10-30 Q2 · Q3):变更记录的【成批】读法 —— /settings/change-history 的一页与它的导出都读它。
-- 【与 change_log_rows 的关系】同一道门(data.view_change_log)、同一套筛选、同一段逐行遮蔽(change_log_mask_row → 那一行自己那张表的读规则
--   → trail_row_record / trail_refs),交出的行与页面原来那一圈 change_log_rows(p_by_entry => true) 调用【逐行相同】(fixture 304,七个角色)。
--   不同的只有三件:① 要哪几次操作只求一次(原来每一次调用都把整张表按事务分组一遍:年体量种子上 81 次 × 约 145 ms);
--   ② 改成沿 seq 倒序取一个窗口(主键索引)—— 一笔事务在倒序里第一次出现的那一行就是它的最大 seq,所以窗口里的先后就是全表的先后;
--   ③ 一次调用交完 p_entries 次操作的全部行,作为【一个】jsonb(不是一组行)交回 —— PostgREST 的 max_rows = 1000 截的是行,截不到它。
-- 【分页】p_before = 上一块最旧那次操作的最大 seq(next_before);在它上面还有行的事务属于上一块,剔掉 —— 导出照这个一块一块往前读,
--   一笔事务永远不会被切成两块。exhausted = 这一块没凑满 p_entries 次。
-- 【p_entries】1..1001(页面:显示 show 条再多读一条;只看关键事件时多读到 5 倍,上限 1,000 —— 与 page.tsx 原来那一圈同一个数)。
-- 【SECURITY DEFINER 的理由】与 change_log_rows 相同:change_log 对应用角色没有任何授权;读 auth.users 取邮箱与账号是否还在。
CREATE OR REPLACE FUNCTION public.change_log_page(p_from date DEFAULT NULL::date, p_to date DEFAULT NULL::date, p_table text DEFAULT NULL::text, p_tables text[] DEFAULT NULL::text[], p_record_ids text[] DEFAULT NULL::text[], p_actor uuid DEFAULT NULL::uuid, p_no_session boolean DEFAULT false, p_removed_account boolean DEFAULT false, p_entries integer DEFAULT 21, p_before bigint DEFAULT NULL::bigint)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
#variable_conflict use_column
DECLARE
    r        record;
    v_mask   jsonb;
    v_entries integer := LEAST(GREATEST(COALESCE(p_entries, 21), 1), 1001);
    v_txids  bigint[];
    v_mx     bigint[];
    v_vkey   text;
    v_vis    boolean;
    v_cache  jsonb := '{}'::jsonb;
    v_acache jsonb := '{}'::jsonb;
    v_akey   text;
    v_cimg   record;
    v_old    jsonb;
    v_new    jsonb;
    v_rr     boolean;
    v_actor  jsonb;
    v_bt     jsonb;
    v_refs   jsonb;
    v_out    jsonb[] := ARRAY[]::jsonb[];
    v_n      integer;
    v_win    integer;
    v_wrows  bigint;
BEGIN
    PERFORM require_permission('data.view_change_log');

    -- ① 这一次要哪几次操作:按事务里(符合筛选的)最大 seq 倒序 —— 与 change_log_rows 同一个定义,但不再每次把整张表按事务分组:
    --   沿 seq 倒序取一个窗口(主键索引),窗口里每笔事务的最大 seq 就是它在全表里的最大 seq(倒序第一次出现即最大);
    --   窗口里凑不满 p_entries 笔就把窗口放大四倍再取。p_before:窗口从它下面开始,并剔除在它上面还有行的事务(那几笔属于上一页)。
    v_win := v_entries * 16;
    LOOP
        WITH w AS MATERIALIZED (
                    SELECT c.txid, c.seq
                      FROM change_log c
                     WHERE (p_before IS NULL OR c.seq < p_before)
                       AND (p_from IS NULL OR c.occurred_at >= p_from::timestamptz)
                       AND (p_to IS NULL OR c.occurred_at < (p_to + 1)::timestamptz)
                       AND (p_table IS NULL OR c.table_name = p_table)
                       AND (p_tables IS NULL OR c.table_name = ANY (p_tables))
                       AND (p_record_ids IS NULL OR EXISTS (SELECT 1 FROM jsonb_each_text(c.row_key) k WHERE k.value = ANY (p_record_ids)))
                       AND (p_actor IS NULL OR c.actor_account = p_actor OR c.actor_employee = p_actor)
                       AND (NOT COALESCE(p_no_session, false) OR c.actor_kind = 'no_session')
                       AND (NOT COALESCE(p_removed_account, false)
                            OR (c.actor_kind = 'user' AND c.actor_employee IS NULL
                                AND NOT EXISTS (SELECT 1 FROM auth.users u2 WHERE u2.id = c.actor_account)))
                     ORDER BY c.seq DESC
                     LIMIT v_win)
        SELECT (SELECT count(*) FROM w), array_agg(g.g_tx ORDER BY g.g_mx DESC), array_agg(g.g_mx ORDER BY g.g_mx DESC)
          INTO v_wrows, v_txids, v_mx FROM (
            SELECT w.txid AS g_tx, max(w.seq) AS g_mx
              FROM w
             GROUP BY w.txid
            HAVING p_before IS NULL OR NOT EXISTS (
                SELECT 1 FROM change_log c3
                 WHERE c3.txid = w.txid AND c3.seq >= p_before
                   AND (p_from IS NULL OR c3.occurred_at >= p_from::timestamptz)
                   AND (p_to IS NULL OR c3.occurred_at < (p_to + 1)::timestamptz)
                   AND (p_table IS NULL OR c3.table_name = p_table)
                   AND (p_tables IS NULL OR c3.table_name = ANY (p_tables))
                   AND (p_record_ids IS NULL OR EXISTS (SELECT 1 FROM jsonb_each_text(c3.row_key) k WHERE k.value = ANY (p_record_ids)))
                   AND (p_actor IS NULL OR c3.actor_account = p_actor OR c3.actor_employee = p_actor)
                   AND (NOT COALESCE(p_no_session, false) OR c3.actor_kind = 'no_session')
                   AND (NOT COALESCE(p_removed_account, false)
                        OR (c3.actor_kind = 'user' AND c3.actor_employee IS NULL
                            AND NOT EXISTS (SELECT 1 FROM auth.users u3 WHERE u3.id = c3.actor_account))))
             ORDER BY max(w.seq) DESC
             LIMIT v_entries) g;
        EXIT WHEN COALESCE(cardinality(v_txids), 0) >= v_entries OR COALESCE(v_wrows, 0) < v_win;
        v_win := v_win * 4;
    END LOOP;
    IF v_txids IS NULL THEN
        RETURN jsonb_build_object('rows', '[]'::jsonb, 'entries', 0, 'next_before', NULL, 'exhausted', true);
    END IF;
    -- ② 那几次操作里符合筛选的每一行 —— 与 change_log_rows(p_by_entry => true)逐字同一套筛选与同一段逐行遮蔽
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
         WHERE c.txid = ANY (v_txids)
           AND (p_from IS NULL OR c.occurred_at >= p_from::timestamptz)
           AND (p_to IS NULL OR c.occurred_at < (p_to + 1)::timestamptz)
           AND (p_table IS NULL OR c.table_name = p_table)
           AND (p_tables IS NULL OR c.table_name = ANY (p_tables))
           AND (p_record_ids IS NULL OR EXISTS (SELECT 1 FROM jsonb_each_text(c.row_key) k WHERE k.value = ANY (p_record_ids)))
           AND (p_actor IS NULL OR c.actor_account = p_actor OR c.actor_employee = p_actor)
           AND (NOT COALESCE(p_no_session, false) OR c.actor_kind = 'no_session')
           AND (NOT COALESCE(p_removed_account, false)
                OR (c.actor_kind = 'user' AND c.actor_employee IS NULL AND u.id IS NULL))
         ORDER BY c.seq DESC
    LOOP
        -- 人名:同一次调用里同一个 (kind, 账号, 员工) 只问一次
        v_akey := r.c_kind || '|' || COALESCE(r.c_account::text, '') || '|' || COALESCE(r.c_employee::text, '');
        IF v_acache ? v_akey THEN
            v_actor := v_acache -> v_akey;
        ELSE
            v_actor := trail_actor(r.c_kind, r.c_account, r.c_employee);
            v_acache := v_acache || jsonb_build_object(v_akey, v_actor);
        END IF;

        v_mask := change_log_mask_row(r.c_table, r.c_key, r.c_old, r.c_new);
        v_old := NULLIF(v_mask -> 'old', 'null'::jsonb);
        v_new := NULLIF(v_mask -> 'new', 'null'::jsonb);
        v_rr := (v_mask ->> 'row_restricted')::boolean;
        v_vkey := r.c_table || '|' || COALESCE(r.c_key::text, '');
        IF v_cache ? v_vkey THEN
            v_vis := (v_cache ->> v_vkey)::boolean;
        ELSE
            SELECT * INTO v_cimg FROM trail_current_image(r.c_table, r.c_key);
            v_vis := COALESCE(trail_row_visible(r.c_table, r.c_key, COALESCE(v_cimg.image, r.c_new, r.c_old)), false);
            v_cache := v_cache || jsonb_build_object(v_vkey, v_vis);
        END IF;
        IF NOT v_vis AND NOT v_rr THEN
            v_old := change_log_restrict(r.c_old, NULL);
            v_new := change_log_restrict(r.c_new, NULL);
            v_rr := true;
        END IF;
        IF v_rr OR r.c_table = 'auth.users' THEN
            v_bt := NULL;
            v_refs := '{}'::jsonb;
        ELSE
            v_bt := trail_row_record(r.c_table, r.c_key, v_old, v_new);
            v_refs := trail_refs(r.c_table, v_old, v_new, r.c_key);
        END IF;
        v_out := v_out || jsonb_build_object(
            'seq', r.c_seq, 'occurred_at', r.c_at, 'table_name', r.c_table, 'row_key', r.c_key, 'op', r.c_op,
            'actor_account', r.c_account, 'actor_email', r.c_email, 'actor_employee', r.c_employee,
            'actor_employee_code', r.c_emp_code, 'actor_employee_name', r.c_emp_name, 'actor_kind', r.c_kind,
            'db_role', r.c_role, 'changed_columns', to_jsonb(r.c_cols), 'old', v_old, 'new', v_new,
            'redacted_at', r.c_redacted, 'row_restricted', v_rr, 'txid', r.c_tx, 'actor', v_actor,
            'belongs_to', v_bt, 'refs', v_refs);
    END LOOP;
    v_n := cardinality(v_txids);
    RETURN jsonb_build_object('rows', to_jsonb(v_out), 'entries', v_n,
        'next_before', v_mx[v_n],
        'exhausted', v_n < v_entries);
END;
$function$;

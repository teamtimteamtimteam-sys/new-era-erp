-- db/functions/record_trail.sql
-- AUDIT-TRAIL-1a(Tim 的 Q1–Q6 · Q12 · Q13 · Q17 · Q40):一页底部"Audit trail"的【唯一】读法。
--
-- 【页面只说"哪一种记录、哪一条"】p_subject 是 trail_subjects() 里的一个主语,不是表名;p_id 是那条记录的 id。
--   不认识的主语 → TRAIL_SUBJECT_UNKNOWN。页面自己的查看权限码不在身上、或那条根记录过不了它自己那张表的读规则
--   (包括根本不存在)→ TRAIL_NOT_PERMITTED。★ 拒绝一律 RAISE,【绝不返回空列表】—— 空列表读起来是"什么都没发生过"。
--
-- 【哪些行】根行 + trail_subject_members() 登记的子行、孙行、相关行(Q3)。子行是【读的时候】找的(Q6):
--   今天还在的行按外键查;删掉了的、或父键被改过的,从 change_log 的影像里查(两条 GIN 部分索引)。
--   ☞ 为什么不能只按影像里的外键找:一次编辑只记改了的那几列,改一条明细行的单价,那一行记录里没有 purchase_order_id。
--     所以先收齐【这条记录有哪些行的主键】,再按 (表, 主键) 取那些行的全部记录。
--
-- 【每一行再过一次它自己那张表的读规则】(Q4)trail_row_visible。过不了的行照样占一个位置(时间还在),
--   其余一律为空、row_hidden = true —— 界面在"做了什么"与"谁"的位置印 Restricted。
-- 【遮蔽】过得了的行走 change_log_mask_row —— 与 /settings/change-history 同一步、同一份 HISTORY-1 规则,不加规则。
--
-- 【一次操作 = 一笔事务 = 一条记录】(Q2)按 txid 分组,entry_no 从新到旧编号。
-- 【变更记录开始之前】(Q1)trail_prelog_sources() 登记的领域历史与生命周期戳,凡是早于 change_log_began_at() 的,
--   拼成 prelog = true 的行(没有 seq);同一时刻写下的归成一条(同一笔事务的 now() 相同)。它们永远排在所有
--   变更记录之后,界面在两者之间画分界线。change_log 已经记着的(那一行的 INSERT、那一戳的改动)一律不再拼 —— 不会出现两次。
--
-- 【每一行带回】actor(trail_actor)、ctx(这一行今天的样子,已遮蔽 —— 子行的"第几行、哪个物料"从这里取)、
--   refs(trail_refs:每一个指着别处的值 → 名字)。界面把这些造成英文句子(Q40)。
-- 【分页】p_entries 条记录(默认 20,1..500),more 说后面还有没有更旧的。
-- 【SECURITY DEFINER 的理由】change_log 对应用角色没有任何授权(HISTORY-1);读权限在函数体里由上面三道判定。
CREATE OR REPLACE FUNCTION public.record_trail(p_subject text, p_id text, p_entries integer DEFAULT 20)
 RETURNS TABLE(entry_no integer, prelog boolean, seq bigint, occurred_at timestamp with time zone, table_name text, row_key jsonb, op text, actor jsonb, changed_columns text[], old jsonb, new jsonb, ctx jsonb, refs jsonb, row_hidden boolean, row_restricted boolean, more boolean)
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
#variable_conflict use_column
DECLARE
    s        record;
    m        record;
    p        record;
    r        record;
    v_limit  integer := LEAST(GREATEST(COALESCE(p_entries, 20), 1), 500);
    v_root   jsonb;
    v_img    record;
    v_tabs   text[] := ARRAY[]::text[];
    v_keys   jsonb[] := ARRAY[]::jsonb[];
    v_vis    boolean[] := ARRAY[]::boolean[];
    v_ctx    jsonb[] := ARRAY[]::jsonb[];
    v_crefs  jsonb[] := ARRAY[]::jsonb[];
    v_rr     jsonb;
    v_pids   text[];
    v_pk     text[];
    v_found  jsonb[];
    v_found2 jsonb[];
    v_k      jsonb;
    i        integer;
    v_pseudo jsonb := '[]'::jsonb;
    v_at     timestamptz;
    v_cols   text[];
    v_new    jsonb;
    v_op     text;
    v_mask   jsonb;
    v_began  timestamptz := change_log_began_at();
    v_total  integer;
BEGIN
    SELECT ts.* INTO s FROM trail_subjects() ts WHERE ts.subject = p_subject;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'TRAIL_SUBJECT_UNKNOWN|%', COALESCE(p_subject, '');
    END IF;
    IF NOT has_permission(s.view_code) THEN
        RAISE EXCEPTION 'TRAIL_NOT_PERMITTED|%', p_subject;
    END IF;
    v_root := jsonb_build_object(s.root_key, p_id);
    SELECT * INTO v_img FROM trail_current_image(s.root_table, v_root);
    IF v_img.image IS NULL OR NOT trail_row_visible(s.root_table, v_root, v_img.image) THEN
        RAISE EXCEPTION 'TRAIL_NOT_PERMITTED|%', p_subject;
    END IF;
    v_tabs := ARRAY[s.root_table];
    v_keys := ARRAY[v_root];

    -- ① 这条记录有哪些行(按 ord 展开,孙行在父行之后)
    FOR m IN SELECT tm.* FROM trail_subject_members() tm WHERE tm.subject = p_subject ORDER BY tm.ord LOOP
        SELECT array_agg(DISTINCT u.k ->> 'id') INTO v_pids
          FROM unnest(v_tabs, v_keys) AS u(t, k) WHERE u.t = m.parent_table AND u.k ? 'id';
        CONTINUE WHEN v_pids IS NULL;
        v_pk := trail_pk_columns(m.table_name);
        EXECUTE format('SELECT array_agg(jsonb_build_object(%s)) FROM public.%I t WHERE t.%I::text = ANY ($1) AND to_jsonb(t) @> $2',
                       (SELECT string_agg(format('%L, t.%I', c, c), ', ') FROM unnest(v_pk) c),
                       m.table_name, m.fk_column)
           INTO v_found USING v_pids, m.match;
        SELECT array_agg(DISTINCT c.row_key) INTO v_found2
          FROM unnest(v_pids) AS pid(v)
          JOIN change_log c ON c.table_name = m.table_name
                           AND (COALESCE(c.new, c.old) @> (jsonb_build_object(m.fk_column, pid.v) || m.match)
                                OR (c.op = 'UPDATE' AND c.old @> jsonb_build_object(m.fk_column, pid.v)));
        FOR v_k IN SELECT DISTINCT x FROM unnest(COALESCE(v_found, ARRAY[]::jsonb[]) || COALESCE(v_found2, ARRAY[]::jsonb[])) x
                    WHERE x IS NOT NULL LOOP
            IF NOT EXISTS (SELECT 1 FROM unnest(v_tabs, v_keys) u(t, k) WHERE u.t = m.table_name AND u.k = v_k) THEN
                v_tabs := array_append(v_tabs, m.table_name);
                v_keys := array_append(v_keys, v_k);
            END IF;
        END LOOP;
    END LOOP;

    -- ② 每一行:过不过它自己那张表的读规则;今天的样子(遮蔽之后);"记录开始之前"的那一段从哪里拼
    FOR i IN 1 .. cardinality(v_tabs) LOOP
        SELECT * INTO v_img FROM trail_current_image(v_tabs[i], v_keys[i]);
        v_vis := array_append(v_vis, i = 1 OR COALESCE(trail_row_visible(v_tabs[i], v_keys[i], v_img.image), false));
        IF v_vis[i] AND v_img.image IS NOT NULL THEN
            v_mask := change_log_mask_row(v_tabs[i], v_keys[i], NULL, v_img.image);
            v_ctx := array_append(v_ctx, COALESCE(NULLIF(v_mask -> 'new', 'null'::jsonb), '{}'::jsonb)
                                         || jsonb_build_object('$gone', v_img.gone));
            v_crefs := array_append(v_crefs, trail_refs(v_tabs[i], NULL, NULL, v_ctx[i]));
        ELSE
            v_ctx := array_append(v_ctx, NULL::jsonb);
            v_crefs := array_append(v_crefs, '{}'::jsonb);
        END IF;
        CONTINUE WHEN v_img.image IS NULL OR v_img.gone;
        FOR p IN SELECT ps.* FROM trail_prelog_sources() ps WHERE ps.table_name = v_tabs[i] LOOP
            v_at := NULLIF(v_img.image ->> p.at_column, '')::timestamptz;
            CONTINUE WHEN v_at IS NULL OR v_at >= v_began;
            IF p.kind = 'created' THEN
                CONTINUE WHEN EXISTS (SELECT 1 FROM change_log c
                                       WHERE c.table_name = v_tabs[i] AND c.row_key = v_keys[i] AND c.op = 'INSERT');
                v_op := 'INSERT';
                v_cols := NULL;
                v_new := v_img.image;
            ELSE
                CONTINUE WHEN EXISTS (SELECT 1 FROM change_log c
                                       WHERE c.table_name = v_tabs[i] AND c.row_key = v_keys[i]
                                         AND (p.at_column = ANY (c.changed_columns)
                                              OR (c.op = 'INSERT' AND c.new ->> p.at_column IS NOT NULL)));
                v_op := 'UPDATE';
                v_cols := ARRAY[p.at_column] || COALESCE(ARRAY[p.by_column], ARRAY[]::text[]) || COALESCE(p.extra, ARRAY[]::text[]);
                v_cols := ARRAY(SELECT c FROM unnest(v_cols) c WHERE c IS NOT NULL);
                SELECT jsonb_object_agg(c, v_img.image -> c) INTO v_new FROM unnest(v_cols) c WHERE v_img.image ? c;
            END IF;
            v_pseudo := v_pseudo || jsonb_build_array(jsonb_build_object(
                'i', i, 'at', v_at, 'op', v_op, 'cols', to_jsonb(v_cols), 'new', v_new,
                'account', CASE WHEN p.by_column IS NULL THEN NULL ELSE v_img.image -> p.by_column END));
        END LOOP;
    END LOOP;

    -- ③ 变更记录 + 拼回来的那一段,按记录(事务)编号,从新到旧
    SELECT count(DISTINCT g) INTO v_total FROM (
        SELECT 'L' || c.txid AS g
          FROM unnest(v_tabs, v_keys) u(t, k) JOIN change_log c ON c.table_name = u.t AND c.row_key = u.k
        UNION ALL
        SELECT 'P' || (x ->> 'at') FROM jsonb_array_elements(v_pseudo) x) z;

    FOR r IN
        WITH k AS (
            SELECT u.t, u.k, u.i::integer AS i FROM unnest(v_tabs, v_keys) WITH ORDINALITY u(t, k, i)),
        allr AS (
            SELECT c.seq AS a_seq, c.occurred_at AS a_at, 'L' || c.txid AS a_g, k.i AS a_i, c.op AS a_op,
                   c.actor_kind AS a_kind, c.actor_account AS a_account, c.actor_employee AS a_employee,
                   c.changed_columns AS a_cols, c.old AS a_old, c.new AS a_new, false AS a_pre
              FROM k JOIN change_log c ON c.table_name = k.t AND c.row_key = k.k
            UNION ALL
            SELECT NULL::bigint, (x ->> 'at')::timestamptz, 'P' || (x ->> 'at'), (x ->> 'i')::integer, x ->> 'op',
                   'prelog', (x ->> 'account')::uuid, NULL::uuid,
                   CASE WHEN jsonb_typeof(x -> 'cols') = 'array'
                        THEN ARRAY(SELECT jsonb_array_elements_text(x -> 'cols')) END,
                   NULL::jsonb, x -> 'new', true
              FROM jsonb_array_elements(v_pseudo) x),
        ent AS (
            SELECT a_g AS e_g, bool_or(a_pre) AS e_pre, max(a_seq) AS e_mx, max(a_at) AS e_at FROM allr GROUP BY a_g),
        num AS (
            SELECT e_g, row_number() OVER (ORDER BY e_pre, e_mx DESC NULLS LAST, e_at DESC, e_g)::integer AS e_n FROM ent)
        SELECT allr.*, num.e_n FROM allr JOIN num ON num.e_g = allr.a_g
         WHERE num.e_n <= v_limit
         ORDER BY num.e_n, allr.a_seq NULLS LAST, allr.a_i
    LOOP
        entry_no := r.e_n;
        prelog := r.a_pre;
        seq := r.a_seq;
        occurred_at := r.a_at;
        more := v_total > v_limit;
        IF NOT v_vis[r.a_i] THEN
            table_name := NULL; row_key := NULL; op := NULL; actor := NULL; changed_columns := NULL;
            old := NULL; new := NULL; ctx := NULL; refs := NULL;
            row_hidden := true;
            row_restricted := true;
        ELSE
            table_name := v_tabs[r.a_i];
            row_key := v_keys[r.a_i];
            op := r.a_op;
            actor := trail_actor(r.a_kind, r.a_account, r.a_employee);
            changed_columns := r.a_cols;
            v_mask := change_log_mask_row(v_tabs[r.a_i], v_keys[r.a_i], r.a_old, r.a_new);
            old := NULLIF(v_mask -> 'old', 'null'::jsonb);
            new := NULLIF(v_mask -> 'new', 'null'::jsonb);
            row_restricted := (v_mask ->> 'row_restricted')::boolean;
            ctx := v_ctx[r.a_i];
            -- 这一行今天那份的名字(每个主键只解析一次)+ 这一次记录里新旧值的名字,按列合并
            v_rr := trail_refs(v_tabs[r.a_i], old, new, NULL);
            SELECT COALESCE(jsonb_object_agg(kk, COALESCE(v_crefs[r.a_i] -> kk, '{}'::jsonb) || COALESCE(v_rr -> kk, '{}'::jsonb)),
                            '{}'::jsonb)
              INTO refs
              FROM (SELECT jsonb_object_keys(v_crefs[r.a_i]) AS kk UNION SELECT jsonb_object_keys(v_rr)) z;
            row_hidden := false;
        END IF;
        RETURN NEXT;
    END LOOP;
END;
$function$;

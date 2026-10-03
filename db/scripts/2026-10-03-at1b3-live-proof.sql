-- db/scripts/2026-10-03-at1b3-live-proof.sql
-- AUDIT-TRAIL-1b-3 · 活库上的证明 —— 整支是【一笔回滚的事务】,文件以 ROLLBACK 收尾。
--   A 只读:线上【每一张】任务(没删的 3 张,连同删掉的 —— 读规则不过滤 deleted_at),以 tim@(cfo,634c00f9)的身份读
--     record_trail,与它原来那一段"变更记录"的来源表(task_history)逐行对照:每一行修改史都在新的记录里吗?缺的逐行点名。
--     三个阈值面板各读一次;线上真有的每一类删掉的记录(客户 · 供应商 · 物料 · 报价)各读一条。整份记录吐出来(\o 那一段),
--     交回报告用 lib/trail/render.ts 造成句子,再逐行对着旧的那一段看。
--   B 在这一笔事务里:以 admin@(321f1819,持全部码;员工 EMP-2026-0002)建一种物料、一个库位、一张私人任务,各改一次
--     (物料:改规格 · 化验要求 · 删掉;库位:改名 + 换一个允许分类 —— 一次 save_storage_location;任务:加步骤 · 打勾 · 改标题),
--     然后以登录账号的身份读这三条记录:物料与库位以 tim@ 读,私人任务以它的归属人 admin@ 读(Q3:打得开它的人看得见)。ROLLBACK。
--     审批开着:这一笔里没有一张单据进审批 —— 物料、库位、任务都不是审批的单据;整笔都不在了。
-- 跑法:psql "$DSN" -X -q -v ON_ERROR_STOP=1 -v out=<目录> -f db/scripts/2026-10-03-at1b3-live-proof.sql
BEGIN;
SET LOCAL statement_timeout = '600s';

-- ── A · 只读:每一张任务,原来"变更记录"的每一行都在新的记录里 ─────────────────────────────────
DO $a$
DECLARE
    d record; v_j jsonb; v_old int; v_found int; t_old int := 0; t_found int := 0; t_docs int := 0; v_miss text; t_miss text := '';
    k text; v_n int;
BEGIN
    -- 每一张以它【归属人】的账号读(归属人永远打得开自己的任务,Q3);tim@(cfo)不持 module.tasks.view_all,读别人的私人任务
    --   被按名拒 —— 那是对的,私人任务对别人是私的。归属人没有账号的退回 tim@;被拒就照直报出来
    FOR d IN SELECT tk.id, tk.code, tk.task_type, tk.deleted_at IS NOT NULL AS gone, COALESCE(e.user_id, '634c00f9-c3a9-4444-9eed-b624cb6a2a93'::uuid) AS reader,
                    (SELECT u.email FROM auth.users u WHERE u.id = COALESCE(e.user_id, '634c00f9-c3a9-4444-9eed-b624cb6a2a93'::uuid)) AS who
               FROM tasks tk LEFT JOIN employees e ON e.id = tk.owner_id ORDER BY tk.deleted_at IS NOT NULL, tk.code LOOP
        PERFORM set_config('request.jwt.claims', json_build_object('sub', d.reader, 'role', 'authenticated')::text, true);
        BEGIN
            EXECUTE 'SET LOCAL ROLE authenticated';
            SELECT jsonb_agg(to_jsonb(r)) INTO v_j FROM record_trail('task', d.id::text, 500) r;
            EXECUTE 'RESET ROLE';
        EXCEPTION WHEN OTHERS THEN
            EXECUTE 'RESET ROLE';
            RAISE NOTICE 'LIVE_A task % (%) REFUSED for % — %', d.code, d.task_type, d.who, SQLERRM;
            t_miss := t_miss || d.code || ' (refused) ';
            CONTINUE;
        END;
        SELECT count(*), count(*) FILTER (WHERE EXISTS (SELECT 1 FROM jsonb_array_elements(COALESCE(v_j, '[]'::jsonb)) e
                  WHERE e ->> 'table_name' = 'task_history' AND e -> 'row_key' ->> 'id' = h.id::text AND NOT (e ->> 'row_hidden')::boolean)),
               string_agg(h.change_type, ',') FILTER (WHERE NOT EXISTS (SELECT 1 FROM jsonb_array_elements(COALESCE(v_j, '[]'::jsonb)) e
                  WHERE e ->> 'table_name' = 'task_history' AND e -> 'row_key' ->> 'id' = h.id::text))
          INTO v_old, v_found, v_miss FROM task_history h WHERE h.task_id = d.id;
        RAISE NOTICE 'LIVE_A task % (%) read by %: old history rows % · found in the trail % · trail rows %', d.code,
            d.task_type || CASE WHEN d.gone THEN ', deleted' ELSE '' END, d.who, v_old, v_found, jsonb_array_length(COALESCE(v_j, '[]'::jsonb));
        IF v_miss IS NOT NULL THEN t_miss := t_miss || d.code || ' (' || v_miss || ') '; END IF;
        t_old := t_old + v_old; t_found := t_found + v_found; t_docs := t_docs + 1;
    END LOOP;
    RAISE NOTICE 'LIVE_A total: % tasks · % old history rows · % found · missing: %', t_docs, t_old, t_found, COALESCE(NULLIF(t_miss, ''), 'none');
    PERFORM set_config('request.jwt.claims', '{"sub":"634c00f9-c3a9-4444-9eed-b624cb6a2a93","role":"authenticated"}', true);
    FOREACH k IN ARRAY ARRAY['processing_settings', 'pricing_settings', 'receiving_settings'] LOOP
        EXECUTE 'SET LOCAL ROLE authenticated';
        SELECT count(*) INTO v_n FROM record_trail(k, 'true', 20);
        EXECUTE 'RESET ROLE';
        RAISE NOTICE 'LIVE_A panel %: % trail rows for tim@ (not refused)', k, v_n;
    END LOOP;
END;
$a$;

-- A 的整份记录(一行一条),给 lib/trail/render.ts 造句:每一张任务 · 三个面板 · 每一类删掉的记录各一条
SELECT set_config('request.jwt.claims', '{"sub":"634c00f9-c3a9-4444-9eed-b624cb6a2a93","role":"authenticated"}', true) \g /dev/null
SET LOCAL ROLE authenticated;
\pset tuples_only on
\pset format unaligned
\o :out/live-a.jsonl
SELECT jsonb_build_object('s', x.s, 'id', x.id, 'l', x.code, 'rows', COALESCE((SELECT jsonb_agg(to_jsonb(r) ORDER BY r.entry_no, r.seq NULLS LAST, r.occurred_at)
         FROM record_trail(x.s, x.id, 500) r), '[]'::jsonb))
  -- 任务那一段:tim@ 打得开的(团队任务);别人的私人任务对他是私的,不在这一份里(上面 A 以归属人读过、逐行对过)
  FROM (SELECT 'task' AS s, id::text AS id, code || CASE WHEN deleted_at IS NULL THEN '' ELSE ' (deleted)' END AS code, 1 AS o FROM tasks WHERE task_type = 'team'
        UNION ALL SELECT k, 'true', k, 2 FROM unnest(ARRAY['processing_settings', 'pricing_settings', 'receiving_settings']) k
        UNION ALL (SELECT 'customer', id::text, code || ' (deleted)', 3 FROM customers WHERE deleted_at IS NOT NULL ORDER BY code LIMIT 1)
        UNION ALL (SELECT 'supplier', id::text, code || ' (deleted)', 3 FROM suppliers WHERE deleted_at IS NOT NULL ORDER BY code LIMIT 1)
        UNION ALL (SELECT 'material', id::text, code || ' (deleted)', 3 FROM materials WHERE deleted_at IS NOT NULL ORDER BY code LIMIT 1)
        UNION ALL (SELECT 'quote', id::text, code || ' (deleted)', 3 FROM quotes WHERE deleted_at IS NOT NULL ORDER BY code LIMIT 1)) x
 ORDER BY x.o, x.code;
\o
RESET ROLE;

-- ── B · 在这一笔里建、改、读(随后整笔回滚)─────────────────────────────────────────────
DO $b$
DECLARE
    k_admin constant uuid := '321f1819-8449-48f7-9ae0-78b2c4b50f35';
    v_emp uuid; v_mat uuid; v_loc uuid; v_task uuid; v_node uuid; w1 text; w2 text; v_s bigint; v_n int;
BEGIN
    SELECT id INTO v_emp FROM employees WHERE user_id = k_admin;
    SELECT code INTO w1 FROM waste_classifications WHERE is_active ORDER BY sort_order, code LIMIT 1;
    SELECT code INTO w2 FROM waste_classifications WHERE is_active ORDER BY sort_order, code OFFSET 1 LIMIT 1;
    IF v_emp IS NULL OR w2 IS NULL THEN RAISE EXCEPTION 'LIVE_B setup: employee % / second waste class %', v_emp, w2; END IF;
    PERFORM set_config('request.jwt.claims', format('{"sub":"%s","role":"authenticated"}', k_admin), true);
    EXECUTE 'SET LOCAL ROLE authenticated';
    -- 物料:建 · 改规格 · 化验要求 · 删掉(取号由触发器)
    INSERT INTO materials (name, kind_code, may_be_processed, form_code, source_code)
    VALUES ('AT-1b-3 proof material (rolled back)', 'battery_material', true, 'black_mass', 'end_of_life') RETURNING id INTO v_mat;
    UPDATE materials SET spec = 'AT-1b-3 live proof — rolled back' WHERE id = v_mat;
    PERFORM set_material_required_metals(v_mat, ARRAY['ni', 'co']);
    UPDATE materials SET deleted_at = now() WHERE id = v_mat;
    -- 库位:一次 save_storage_location 建(带一个允许分类);再一次 —— 改名 + 换一个分类(Q13:只写变了的)
    v_loc := save_storage_location('ZZ-AT1B3-PROOF', 'AT-1b-3 proof bay (rolled back)', ARRAY[w1], NULL, 'P', NULL);
    -- change_log 对应用角色没有任何授权 —— 数"这一次保存写了几行"要回到属主身份读
    EXECUTE 'RESET ROLE';
    SELECT max(seq) INTO v_s FROM change_log;
    EXECUTE 'SET LOCAL ROLE authenticated';
    PERFORM save_storage_location('ZZ-AT1B3-PROOF', 'AT-1b-3 proof bay (renamed)', ARRAY[w2], v_loc, 'P', NULL);
    EXECUTE 'RESET ROLE';
    SELECT count(*) INTO v_n FROM change_log WHERE seq > v_s;
    RAISE NOTICE 'LIVE_B the rename + class swap wrote % change-log rows: %', v_n,
        (SELECT string_agg(table_name || ' ' || op || COALESCE(' ' || array_to_string(changed_columns, '+'), ''), '; ' ORDER BY seq) FROM change_log WHERE seq > v_s);
    IF v_n <> 3 THEN RAISE EXCEPTION 'LIVE_B the location save should write exactly 3 rows (1 update, 1 delete, 1 insert), wrote %', v_n; END IF;
    EXECUTE 'SET LOCAL ROLE authenticated';
    -- 私人任务(Q3):建 · 加步骤 · 打勾 · 改标题
    INSERT INTO tasks (code, title, task_type, owner_id) VALUES ('', 'AT-1b-3 proof task (rolled back)', 'personal', v_emp) RETURNING id INTO v_task;
    INSERT INTO task_nodes (task_id, title, sort_order, created_by) VALUES (v_task, 'Check the trail', 1024, v_emp) RETURNING id INTO v_node;
    UPDATE task_nodes SET done = true, done_at = now(), done_by = v_emp WHERE id = v_node;
    UPDATE tasks SET title = 'AT-1b-3 proof task (renamed)' WHERE id = v_task;
    EXECUTE 'RESET ROLE';
    CREATE TEMP TABLE at1b3_proof_ids ON COMMIT DROP AS
        SELECT 'material'::text AS s, v_mat AS id, '634c00f9-c3a9-4444-9eed-b624cb6a2a93'::uuid AS reader
        UNION ALL SELECT 'storage_location', v_loc, '634c00f9-c3a9-4444-9eed-b624cb6a2a93'::uuid
        UNION ALL SELECT 'task', v_task, k_admin;
    GRANT SELECT ON at1b3_proof_ids TO authenticated;   -- 下面以登录账号的身份读它(随事务一起消失)
    RAISE NOTICE 'LIVE_B created material %, location ZZ-AT1B3-PROOF, task % inside the transaction',
        (SELECT code FROM materials WHERE id = v_mat), (SELECT code FROM tasks WHERE id = v_task);
END;
$b$;

-- B 的三条记录:物料与库位以 tim@ 读,私人任务以它的归属人 admin@ 读(都是登录的账号)
SELECT set_config('request.jwt.claims', '{"sub":"634c00f9-c3a9-4444-9eed-b624cb6a2a93","role":"authenticated"}', true) \g /dev/null
SET LOCAL ROLE authenticated;
\o :out/live-b.jsonl
SELECT jsonb_build_object('s', p.s, 'id', p.id, 'l', p.s || ' (proof, read by tim@)', 'rows', COALESCE((SELECT jsonb_agg(to_jsonb(r) ORDER BY r.entry_no, r.seq NULLS LAST, r.occurred_at)
         FROM record_trail(p.s, p.id::text, 50) r), '[]'::jsonb))
  FROM at1b3_proof_ids p WHERE p.reader = '634c00f9-c3a9-4444-9eed-b624cb6a2a93' ORDER BY p.s;
\o
RESET ROLE;
SELECT set_config('request.jwt.claims', '{"sub":"321f1819-8449-48f7-9ae0-78b2c4b50f35","role":"authenticated"}', true) \g /dev/null
SET LOCAL ROLE authenticated;
\o :out/live-b2.jsonl
SELECT jsonb_build_object('s', p.s, 'id', p.id, 'l', p.s || ' (proof, read by its owner admin@)', 'rows', COALESCE((SELECT jsonb_agg(to_jsonb(r) ORDER BY r.entry_no, r.seq NULLS LAST, r.occurred_at)
         FROM record_trail(p.s, p.id::text, 50) r), '[]'::jsonb))
  FROM at1b3_proof_ids p WHERE p.reader = '321f1819-8449-48f7-9ae0-78b2c4b50f35' ORDER BY p.s;
\o
RESET ROLE;

ROLLBACK;

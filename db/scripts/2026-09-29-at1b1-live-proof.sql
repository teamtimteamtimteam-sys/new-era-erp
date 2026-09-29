-- db/scripts/2026-09-29-at1b1-live-proof.sql
-- AUDIT-TRAIL-1b-1 · 活库上的证明 —— 整支是【一笔回滚的事务】,文件以 ROLLBACK 收尾。
--   A 只读:线上【每一张】进料与产出批次,以 admin@(持 71 / 72 个码,缺的那个是 module.tasks.view_all,与批次无关)的身份读
--     record_trail,与旧视图 batch_audit_trail_all 逐行对照:旧视图的每一行,它的来源行(source_table, source_id)都在新的
--     记录里吗?缺的逐行点名;按种类报数;往上一跳的那几种单独报数。
--   B 在这一笔事务里:以仓库的账号(c8116e6c,持 action.processing_aftercare)交一张交接班,读它的审计记录,然后 ROLLBACK。
--     最后一句 SELECT 把那份记录吐出来(json),交回报告用 lib/trail/render.ts 把它造成句子。
-- 跑法:psql "$DSN" -X -q -v ON_ERROR_STOP=1 -f db/scripts/2026-09-29-at1b1-live-proof.sql
BEGIN;
SET LOCAL statement_timeout = '600s';

DO $a$
DECLARE
    b record; v_j jsonb; v_old int; v_miss int; v_rows int;
    t_batches int := 0; t_old int := 0; t_miss int := 0; t_rows int := 0; t_hidden int := 0;
    v_list text := '';
    k record;
BEGIN
    PERFORM set_config('request.jwt.claims', '{"sub":"321f1819-8449-48f7-9ae0-78b2c4b50f35","role":"authenticated"}', true);
    CREATE TEMP TABLE lv_trail (batch_kind text, batch_id uuid, table_name text, row_id text, hidden boolean) ON COMMIT DROP;
    FOR b IN SELECT 'inbound' AS kind, id, code FROM inbound_batches UNION ALL SELECT 'output', id, code FROM output_batches ORDER BY 3 LOOP
        EXECUTE 'SET LOCAL ROLE authenticated';
        SELECT jsonb_agg(to_jsonb(r)) INTO v_j
          FROM record_trail(CASE WHEN b.kind = 'inbound' THEN 'inbound_batch' ELSE 'output_batch' END, b.id::text, 500) r;
        EXECUTE 'RESET ROLE';
        INSERT INTO lv_trail SELECT b.kind, b.id, e ->> 'table_name', e -> 'row_key' ->> 'id', (e ->> 'row_hidden')::boolean
          FROM jsonb_array_elements(COALESCE(v_j, '[]'::jsonb)) e;
        t_batches := t_batches + 1;
    END LOOP;
    SELECT count(*), count(*) FILTER (WHERE hidden) INTO t_rows, t_hidden FROM lv_trail;
    SELECT count(*) INTO t_old FROM batch_audit_trail_all;
    SELECT count(*), string_agg(o.event_kind || ':' || o.source_table || ':' || o.source_id, ', ')
      INTO t_miss, v_list
      FROM batch_audit_trail_all o
     WHERE NOT EXISTS (SELECT 1 FROM lv_trail l WHERE l.batch_kind = o.batch_kind AND l.batch_id = o.batch_id
                                                  AND l.table_name = o.source_table AND l.row_id = o.source_id::text);
    RAISE NOTICE 'LIVE_A batches read: % · old view rows: % · new trail rows: % (hidden to admin@: %) · old rows missing from the new trail: %',
        t_batches, t_old, t_rows, t_hidden, t_miss;
    IF t_miss > 0 THEN RAISE NOTICE 'LIVE_A missing: %', v_list; END IF;
    FOR k IN SELECT o.event_kind, count(*) AS n,
                    count(*) FILTER (WHERE EXISTS (SELECT 1 FROM lv_trail l WHERE l.batch_kind = o.batch_kind AND l.batch_id = o.batch_id
                                                     AND l.table_name = o.source_table AND l.row_id = o.source_id::text)) AS found
               FROM batch_audit_trail_all o GROUP BY 1 ORDER BY 1 LOOP
        RAISE NOTICE 'LIVE_A kind % : % old rows, % found', rpad(k.event_kind, 18), k.n, k.found;
    END LOOP;
    SELECT count(*) INTO v_old FROM batch_audit_trail_all o LEFT JOIN journal_entries je ON o.source_table = 'journal_entries' AND je.id = o.source_id
     WHERE o.event_kind IN ('cost_entry_change', 'approval', 'work_order_change', 'po_change', 'so_change')
        OR (o.event_kind = 'journal_entry' AND je.source_type IN ('processing_cost', 'allocation', 'stocktake'));
    SELECT count(*) INTO v_miss FROM batch_audit_trail_all o LEFT JOIN journal_entries je ON o.source_table = 'journal_entries' AND je.id = o.source_id
     WHERE (o.event_kind IN ('cost_entry_change', 'approval', 'work_order_change', 'po_change', 'so_change')
            OR (o.event_kind = 'journal_entry' AND je.source_type IN ('processing_cost', 'allocation', 'stocktake')))
       AND EXISTS (SELECT 1 FROM lv_trail l WHERE l.batch_kind = o.batch_kind AND l.batch_id = o.batch_id
                                            AND l.table_name = o.source_table AND l.row_id = o.source_id::text);
    RAISE NOTICE 'LIVE_A upward-hop rows (Q4): % in the old view, % found in the new trail', v_old, v_miss;
    FOR k IN SELECT l.table_name, count(*) AS n FROM lv_trail l
              WHERE NOT l.hidden AND l.table_name NOT IN (SELECT DISTINCT source_table FROM batch_audit_trail_all)
              GROUP BY 1 ORDER BY 1 LOOP
        RAISE NOTICE 'LIVE_A added kind % : % rows', rpad(k.table_name, 30), k.n;
    END LOOP;
    PERFORM set_config('request.jwt.claims', '', true);
END;
$a$;

-- B · 一张交接班,在这一笔事务里交、读、然后随 ROLLBACK 消失
CREATE TEMP TABLE lv_handover (id uuid, trail jsonb) ON COMMIT DROP;
DO $b$
DECLARE v_out uuid; v_in uuid; v_id uuid; v_down uuid; v_j jsonb;
BEGIN
    SELECT id INTO v_out FROM employees WHERE code = 'EMP-2026-0006';
    -- 接班人:任一个别的在册员工(第一版按 tim@ 的主账号找,而那个账号不是任何员工行的 user_id —— 0 行,交接班按名拒 HANDOVER_PEOPLE_REQUIRED)
    SELECT id INTO v_in FROM employees WHERE deleted_at IS NULL AND id <> v_out ORDER BY code LIMIT 1;
    SELECT id INTO v_down FROM equipment_downtime ORDER BY started_at DESC LIMIT 1;
    PERFORM set_config('request.jwt.claims', '{"sub":"c8116e6c-80db-4a16-be12-24fb6ce6859d","role":"authenticated"}', true);
    EXECUTE 'SET LOCAL ROLE authenticated';
    v_id := submit_shift_handover('day', CURRENT_DATE, v_out, v_in, 'AT-1b-1 live proof — rolled back',
        (SELECT jsonb_agg(jsonb_build_object('item_type_code', code, 'body', 'Checked and handed over'))
           FROM handover_item_types WHERE is_required),
        CASE WHEN v_down IS NULL THEN NULL ELSE ARRAY[v_down] END);
    SELECT jsonb_agg(to_jsonb(r) ORDER BY r.entry_no, r.seq) INTO v_j FROM record_trail('shift_handover', v_id::text, 20) r;
    EXECUTE 'RESET ROLE';
    PERFORM set_config('request.jwt.claims', '', true);
    INSERT INTO lv_handover VALUES (v_id, v_j);
    RAISE NOTICE 'LIVE_B handover % submitted as the warehouse account; its trail as that account: % rows', v_id, jsonb_array_length(v_j);
END;
$b$;
SELECT trail FROM lv_handover;

ROLLBACK;

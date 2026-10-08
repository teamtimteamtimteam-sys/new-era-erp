-- db/scripts/2026-10-08-mes5a1-live-role-table.sql
-- MES-5a-1 · 逐角色读数表 —— 七个真账号,对三处页面各自能看见什么、能按什么:
--   放电那一炉的页面(线上唯一的一炉放电 PROC-2026-0494,已回滚)· 它的投料进料批页(ZZ-PROCCOST1-DEMO)· 一张带电未放电的产出批页(OUT-2026-0185)。
--   以 SET LOCAL ROLE authenticated + 那个人的 JWT 读(PostgREST 每一次请求做的就是这件事)。一笔事务,以 ROLLBACK 收尾;只写一张临时表。
--   每一个是 / 否是页面上那个门【问的那一个码】(has_permission —— 与 lib/permissions.ts 的 can() 同一个判据);
--   数字是这个人以自己的身份读那几张视图 / 表得到的行数(0 是"看不见或真的没有" —— 旁边的码分得开这两件事;线上还没有任何放电结果)。
--   跑法:psql "<pooler dsn>" -X -v ON_ERROR_STOP=1 -f 本文件
\pset pager off
\pset format unaligned
BEGIN;   -- 不是 READ ONLY:临时表要写(它随回滚消失);在册的东西一行都不写
SET LOCAL statement_timeout = '120s';

CREATE TEMP TABLE mes5a1_roles (email text, role text,
    run_page boolean, run_status_rows int, run_result_rows int, run_channel_rows int, run_split_rows int,
    record_result boolean, channel_split boolean, split_commit boolean, devices int, quarantine_locs_visible boolean,
    in_page boolean, in_status_rows int, in_set_count boolean,
    out_page boolean, out_status_rows int, out_set_count boolean,
    photo_open boolean, v9_edit boolean, v9_listed int, reminders int) ON COMMIT DROP;
GRANT INSERT ON mes5a1_roles TO authenticated;

DO $rt$
DECLARE r record; v_run uuid; v_ib uuid; v_ob uuid;
BEGIN
    SELECT id INTO v_run FROM processing_runs WHERE code = 'PROC-2026-0494';
    SELECT id INTO v_ib FROM inbound_batches WHERE code = 'ZZ-PROCCOST1-DEMO';
    SELECT id INTO v_ob FROM output_batches WHERE code = 'OUT-2026-0185';
    IF v_run IS NULL OR v_ib IS NULL OR v_ob IS NULL THEN RAISE EXCEPTION 'MES5A1_ROLE|a subject is missing'; END IF;
    FOR r IN SELECT u.id, u.email, (SELECT string_agg(ro.code, ',') FROM user_roles ur JOIN roles ro ON ro.id = ur.role_id
                                     WHERE ur.user_id = u.id AND ur.revoked_at IS NULL) AS role
               FROM auth.users u ORDER BY u.email LOOP
        PERFORM set_config('request.jwt.claims', format('{"sub":"%s","role":"authenticated"}', r.id), true);
        EXECUTE 'SET LOCAL ROLE authenticated';
        INSERT INTO mes5a1_roles VALUES (r.email, r.role,
            has_permission('module.processing.view'),
            (SELECT count(*) FROM discharge_status_by_batch WHERE batch_id = v_ib),
            (SELECT count(*) FROM discharge_module_rows WHERE run_id = v_run),
            (SELECT count(*) FROM discharge_channel_assignments WHERE run_id = v_run),
            (SELECT count(*) FROM discharge_module_splits WHERE discharge_run_id = v_run),
            has_permission('action.confirm_capture'),
            has_permission('action.processing_aftercare'),
            has_permission('action.processing_aftercare') AND has_permission('action.processing_commit'),
            (SELECT count(*) FROM devices WHERE kind = 'discharge_cabinet' AND retired_at IS NULL),
            has_permission('module.inventory.view'),
            has_permission('module.inbound.view'),
            (SELECT count(*) FROM discharge_module_rows WHERE batch_id = v_ib),
            has_permission('module.inbound.edit') OR has_permission('action.processing_commit'),
            has_permission('module.output.view'),
            (SELECT count(*) FROM discharge_module_rows WHERE batch_id = v_ob),
            has_permission('module.output.edit') OR has_permission('action.processing_commit'),
            has_permission('module.inbound.view') OR has_permission('module.logistics.view'),
            has_permission('module.materials.edit'),
            (SELECT count(*) FROM pending_values WHERE value_code = 'V9'),
            (SELECT count(*) FROM operations_now WHERE item_type IN ('discharge_unverified', 'discharge_quarantine_pending')));
        EXECUTE 'RESET ROLE';
    END LOOP;
END;
$rt$;

SELECT 'ROLE', email, role, run_page, run_status_rows, run_result_rows, run_channel_rows, run_split_rows, record_result, channel_split, split_commit,
       devices, quarantine_locs_visible, in_page, in_status_rows, in_set_count, out_page, out_status_rows, out_set_count, photo_open, v9_edit,
       v9_listed, reminders
  FROM mes5a1_roles ORDER BY email;
ROLLBACK;

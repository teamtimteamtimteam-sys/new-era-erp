-- db/scripts/2026-10-07-mes4b-live-role-table.sql
-- MES-4b · 逐角色读数表 —— 七个真账号,对三处页面(/operation/contamination · 加工单页 · 进料批页)各自能看见什么、能按什么。
--   以 SET LOCAL ROLE authenticated + 那个人的 JWT 读(PostgREST 每一次请求做的就是这件事)。一笔事务,以 ROLLBACK 收尾;只写一张临时表。
--   每一个是 / 否是页面上那个门【问的那一个码】(has_permission —— 与 lib/permissions.ts 的 can() 同一个判据),
--   数字是这个人以自己的身份读那几张视图 / 表得到的行数(0 是"看不见或真的没有" —— 旁边的码分得开这两件事)。
--   跑法:psql "<pooler dsn>" -X -v ON_ERROR_STOP=1 -f 本文件
\pset pager off
\pset format unaligned
BEGIN;   -- 不是 READ ONLY:临时表要写(它随回滚消失);在册的东西一行都不写
SET LOCAL statement_timeout = '120s';

CREATE TEMP TABLE mes4b_roles (email text, role text,
    cont_page boolean, cont_grid int, cont_checks int, cont_streams int,
    run_page boolean, run_record_check boolean, run_derive boolean, run_measured_loss boolean, run_electrolyte_edit boolean,
    in_page boolean, in_constructions int, in_set_construction boolean, out_set_construction boolean, dict_edit boolean,
    pv_v10_v11 int) ON COMMIT DROP;
GRANT INSERT ON mes4b_roles TO authenticated;

DO $rt$
DECLARE r record;
BEGIN
    FOR r IN SELECT u.id, u.email, (SELECT string_agg(ro.code, ',') FROM user_roles ur JOIN roles ro ON ro.id = ur.role_id
                                     WHERE ur.user_id = u.id AND ur.revoked_at IS NULL) AS role
               FROM auth.users u ORDER BY u.email LOOP
        PERFORM set_config('request.jwt.claims', format('{"sub":"%s","role":"authenticated"}', r.id), true);
        EXECUTE 'SET LOCAL ROLE authenticated';
        INSERT INTO mes4b_roles VALUES (r.email, r.role,
            has_permission('module.processing.view') OR has_permission('module.output.view'),
            (SELECT count(*) FROM contamination_shift_status), (SELECT count(*) FROM contamination_check_rows),
            (SELECT count(*) FROM contamination_streams),
            has_permission('module.processing.view'),
            has_permission('action.processing_aftercare'),
            has_permission('action.processing_aftercare'),
            has_permission('action.processing_aftercare') OR has_permission('module.processing.edit'),
            has_permission('module.processing.edit'),
            has_permission('module.inbound.view'), (SELECT count(*) FROM cell_constructions),
            has_permission('module.inbound.edit') OR has_permission('action.processing_commit'),
            has_permission('module.output.edit') OR has_permission('action.processing_commit'),
            has_permission('module.processing.edit'),
            (SELECT count(*) FROM pending_values WHERE value_code IN ('V10', 'V11')));
        EXECUTE 'RESET ROLE';
    END LOOP;
END;
$rt$;

SELECT 'ROLE', email, role, cont_page, cont_grid, cont_checks, cont_streams, run_page, run_record_check, run_derive, run_measured_loss,
       run_electrolyte_edit, in_page, in_constructions, in_set_construction, out_set_construction, dict_edit, pv_v10_v11
  FROM mes4b_roles ORDER BY email;
ROLLBACK;

-- db/scripts/2026-10-07-mes4a-live-role-table.sql
-- MES-4a · 逐角色读数表 —— 七个真账号,对三处页面(工序页 · 新加工单 · 加工单页)各自能看见什么、能按什么。
--   以 SET LOCAL ROLE authenticated + 那个人的 JWT 读(PostgREST 每一次请求做的就是这件事)。一笔事务,以 ROLLBACK 收尾;只写一张临时表。
--   每一格是页面上那个门【问的那一个码】(has_permission —— 与 lib/permissions.ts 的 can() 同一个判据),
--   加上这个人以自己的身份读那几张视图 / 表得到的行数(读得到 ≠ 0 是"看得见",0 是"看不见或真的没有" —— 旁边的码分得开这两件事)。
--   跑法:psql "<pooler dsn>" -X -v ON_ERROR_STOP=1 -f 本文件
\pset pager off
\pset format unaligned
BEGIN;   -- 不是 READ ONLY:临时表要写(它随回滚消失);在册的东西一行都不写
SET LOCAL statement_timeout = '120s';

CREATE TEMP TABLE mes4a_roles (email text, role text,
    op_page boolean, op_edit boolean, op_fields int,
    form_commit boolean, form_shifts int, form_weighings int,
    run_page boolean, run_balance_rows int, run_values int, run_aftercare boolean, run_losses boolean, run_header boolean,
    dict_shifts_edit boolean, month_end boolean) ON COMMIT DROP;
GRANT INSERT ON mes4a_roles TO authenticated;

DO $rt$
DECLARE r record;
BEGIN
    FOR r IN SELECT u.id, u.email, (SELECT string_agg(ro.code, ',') FROM user_roles ur JOIN roles ro ON ro.id = ur.role_id
                                     WHERE ur.user_id = u.id AND ur.revoked_at IS NULL) AS role
               FROM auth.users u ORDER BY u.email LOOP
        PERFORM set_config('request.jwt.claims', format('{"sub":"%s","role":"authenticated"}', r.id), true);
        EXECUTE 'SET LOCAL ROLE authenticated';
        INSERT INTO mes4a_roles VALUES (r.email, r.role,
            has_permission('module.processing.view'), has_permission('module.processing.edit'),
            (SELECT count(*) FROM operation_type_fields),
            has_permission('action.processing_commit'), (SELECT count(*) FROM shifts WHERE is_active),
            (SELECT count(*) FROM run_weighing_options),
            has_permission('module.processing.view'), (SELECT count(*) FROM processing_run_balance),
            (SELECT count(*) FROM processing_run_values_current),
            has_permission('action.processing_aftercare'),
            has_permission('action.processing_aftercare') OR has_permission('module.processing.edit'),
            has_permission('action.processing_commit'),
            has_permission('module.processing.edit'), has_permission('module.finance.view'));
        EXECUTE 'RESET ROLE';
    END LOOP;
END;
$rt$;

SELECT 'ROLE', email, role, op_page, op_edit, op_fields, form_commit, form_shifts, form_weighings,
       run_page, run_balance_rows, run_values, run_aftercare, run_losses, run_header, dict_shifts_edit, month_end
  FROM mes4a_roles ORDER BY email;
ROLLBACK;

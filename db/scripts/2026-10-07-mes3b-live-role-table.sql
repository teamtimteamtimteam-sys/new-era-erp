-- db/scripts/2026-10-07-mes3b-live-role-table.sql
-- MES-3b · 逐角色读数表 —— 七个真账号,各自打开一张【在册】进料批与一个【在册】库位的短链接,读一张那一批的标签预览。
--   以 SET LOCAL ROLE authenticated + 那个人的 JWT 读(PostgREST 每一次请求做的就是这件事)。
--   【一笔事务,以 ROLLBACK 收尾】—— 短链接的认身份(resolve_scan_code)每一次都写一行 scan_events,所以这不是一个 READ ONLY 事务;
--   那几行随回滚消失,在册的批次与库位一个字节都不动(读它们的编号而已)。
--   每一格怎么读的写在交回 §1 那张表下面。跑法:psql "<pooler dsn>" -X -v ON_ERROR_STOP=1 -f 本文件
\pset pager off
\pset format unaligned
BEGIN;
SET LOCAL statement_timeout = '120s';

CREATE TEMP TABLE mes3b_roles (email text, role text, b_code text, l_code text, b_link text, b_id_given boolean, b_needs text,
    l_link text, l_id_given boolean, preview text, label_material text, can_print_page boolean, scan_page boolean, can_move boolean,
    dict_dg boolean, dict_tpl boolean, pv_30_31_35 int) ON COMMIT DROP;
GRANT INSERT ON mes3b_roles TO authenticated;

DO $rt$
DECLARE
    r record;
    v_b text := (SELECT code FROM inbound_batches WHERE deleted_at IS NULL AND code LIKE 'IN-%' ORDER BY code LIMIT 1);
    v_bid uuid := (SELECT id FROM inbound_batches WHERE code = (SELECT code FROM inbound_batches WHERE deleted_at IS NULL AND code LIKE 'IN-%' ORDER BY code LIMIT 1));
    v_l text := (SELECT code FROM storage_locations WHERE is_active ORDER BY code LIMIT 1);
    jb jsonb; jl jsonb; jp jsonb; v_prev text;
BEGIN
    FOR r IN SELECT u.id, u.email, (SELECT string_agg(ro.code, ',') FROM user_roles ur JOIN roles ro ON ro.id = ur.role_id
                                     WHERE ur.user_id = u.id AND ur.revoked_at IS NULL) AS role
               FROM auth.users u ORDER BY u.email LOOP
        PERFORM set_config('request.jwt.claims', format('{"sub":"%s","role":"authenticated"}', r.id), true);
        EXECUTE 'SET LOCAL ROLE authenticated';
        jb := resolve_scan_code('/b/' || v_b, 'lookup', 'link');
        jl := resolve_scan_code('/loc/' || v_l, 'lookup', 'link');
        BEGIN
            jp := label_print_preview('inbound_batch', v_bid);
            v_prev := 'ok';
        EXCEPTION WHEN OTHERS THEN
            jp := NULL; v_prev := SQLERRM;
        END;
        INSERT INTO mes3b_roles VALUES (r.email, r.role, v_b, v_l,
            jb ->> 'outcome', jb ->> 'id' IS NOT NULL, jb ->> 'needs',
            jl ->> 'outcome', jl ->> 'id' IS NOT NULL, v_prev, jp #>> '{data,material_name}',
            has_permission('module.inbound.view'), has_permission('module.inventory.view'), has_permission('module.inventory.edit'),
            has_permission('module.materials.view'), has_permission('module.inventory.view'),
            (SELECT count(*) FROM pending_values WHERE value_code IN ('V30', 'V31', 'V35')));
        EXECUTE 'RESET ROLE';
    END LOOP;
END;
$rt$;

SELECT 'ROLE', email, role, b_code, b_link, b_id_given, COALESCE(b_needs, '-'), l_code, l_link, l_id_given,
       preview, COALESCE(label_material, '-'), can_print_page, scan_page, can_move, dict_dg, dict_tpl, pv_30_31_35
  FROM mes3b_roles ORDER BY email;
ROLLBACK;

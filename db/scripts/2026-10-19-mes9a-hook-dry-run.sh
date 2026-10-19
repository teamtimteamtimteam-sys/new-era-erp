#!/usr/bin/env bash
# ════════════════════════════════════════════════════════════════════════════
# MES-9a · Verify 第 3 步 —— 【hook 与 supplier_portal 角色的线上干跑,整笔回滚】(MES-9 Step 0 Q2 · Q11;委托书「Sign-in safety」)
# ════════════════════════════════════════════════════════════════════════════
# 把迁移文件的正文(建角色、建表、建 hook 与门户函数 —— 连同它自己的自证)在线上一笔事务里跑一遍,然后在【同一笔事务里】:
#   · 给七个线上角色(admin · cco · cfo · cto · finance · gm · warehouse)各造一个一次性的【同码副本】角色 + 一个随机账号 id 持它,
#     一个没有角色的随机账号,一个只挂真的 floor_display 的随机账号 —— 对每一个直接调 portal_access_token_hook(event),
#     断言返回的 event 与传进去的【逐字节相同】(员工的令牌一个字节都不变);
#   · 一个一次性门户账号(auth.users 一行 + 一次性供应商 + 联系人 + 链接,都是我自己的、都随回滚消失)→ claims.role = supplier_portal,
#     别的键一个不动;
#   · hook 里的失败(user_id 不是 uuid)→ 原样返回,不抛;
#   · 以 supplier_portal 的身份(SET LOCAL ROLE + 那个账号的令牌声明 + 一个会话行)调 portal_me() → 回它自己的供应商;
#     读一张内部表 / 调 current_user_permissions() → 42501。
# 最后 ROLLBACK:线上什么都没留下(读回:supplier_portal 角色不在、supplier_portal_users 不在)。
# 用法:bash db/scripts/2026-10-19-mes9a-hook-dry-run.sh > <log> 2>&1 ; 判决只读日志里 DRY_OWN_EXIT=。
set -u
cd "$(dirname "$0")/../.."
DSN="${CHECK_MIRRORS_DSN:-host=aws-1-ap-southeast-1.pooler.supabase.com port=5432 user=postgres.wvywpohbwkiinmipmuku dbname=postgres}"
MIG=db/migrations/2026-10-19-mes9a-supplier-portal-identity.sql
TMP=$(mktemp -t mes9adry.XXXXXX)
python3 - "$MIG" "$TMP" <<'PY'
import sys, re
src = open(sys.argv[1]).read()
assert src.rstrip().endswith("COMMIT;"), "migration must end with COMMIT;"
body = src.rstrip()[:-len("COMMIT;")]
proof = r"""
-- ════════ MES-9a hook dry run: claims per identity (still inside the migration's transaction) ════════
CREATE FUNCTION pg_temp.dry_event(p_user text) RETURNS jsonb LANGUAGE sql AS $f$
    SELECT jsonb_build_object('user_id', p_user, 'authentication_method', 'password',
        'claims', jsonb_build_object('aud', 'authenticated', 'exp', 2000000000, 'iat', 1900000000, 'sub', p_user, 'email', 'dry@test.local',
                                     'phone', '', 'role', 'authenticated', 'aal', 'aal1', 'session_id', '00000000-0000-4000-8000-0000000009a3',
                                     'is_anonymous', false, 'app_metadata', jsonb_build_object('provider', 'email'),
                                     'user_metadata', '{}'::jsonb, 'amr', '[]'::jsonb))
$f$;
DO $dry$
DECLARE
    v_code text; v_role uuid; v_copy uuid; u uuid; v_ev jsonb; v_j jsonb; v_n int := 0; v_codes int;
    s uuid; c uuid; up uuid := gen_random_uuid(); sid uuid := gen_random_uuid(); v text;
BEGIN
    FOREACH v_code IN ARRAY ARRAY['admin', 'cco', 'cfo', 'cto', 'finance', 'gm', 'warehouse'] LOOP
        SELECT id INTO v_role FROM roles WHERE code = v_code;
        INSERT INTO roles (code, name_en, name_zh, is_active) VALUES ('zz-mes9a-dry-' || v_code, 'dry', 'dry', true) RETURNING id INTO v_copy;
        INSERT INTO role_permissions (role_id, permission_code) SELECT v_copy, permission_code FROM role_permissions WHERE role_id = v_role;
        GET DIAGNOSTICS v_codes = ROW_COUNT;
        u := gen_random_uuid();
        INSERT INTO user_roles (user_id, role_id) VALUES (u, v_copy);
        v_ev := pg_temp.dry_event(u::text);
        v_j := portal_access_token_hook(v_ev);
        RAISE NOTICE 'DRY|copy of %|% codes|claims unchanged = %|role in token = %', v_code, v_codes, (v_j = v_ev), v_j #>> '{claims,role}';
        IF v_j IS DISTINCT FROM v_ev THEN RAISE EXCEPTION 'DRY_FAIL|the hook changed the claims of a copy of %', v_code; END IF;
        v_n := v_n + 1;
    END LOOP;
    u := gen_random_uuid();
    v_ev := pg_temp.dry_event(u::text); v_j := portal_access_token_hook(v_ev);
    RAISE NOTICE 'DRY|no role|0 codes|claims unchanged = %|role in token = %', (v_j = v_ev), v_j #>> '{claims,role}';
    IF v_j IS DISTINCT FROM v_ev THEN RAISE EXCEPTION 'DRY_FAIL|no-role claims changed'; END IF;
    u := gen_random_uuid();
    INSERT INTO user_roles (user_id, role_id) SELECT u, id FROM roles WHERE code = 'floor_display';
    v_ev := pg_temp.dry_event(u::text); v_j := portal_access_token_hook(v_ev);
    RAISE NOTICE 'DRY|display only (floor_display)|1 code|claims unchanged = %|role in token = %', (v_j = v_ev), v_j #>> '{claims,role}';
    IF v_j IS DISTINCT FROM v_ev THEN RAISE EXCEPTION 'DRY_FAIL|display claims changed'; END IF;
    v_ev := pg_temp.dry_event('not-a-uuid'); v_j := portal_access_token_hook(v_ev);
    RAISE NOTICE 'DRY|internal failure (user_id not a uuid)|-|claims unchanged = %', (v_j = v_ev);
    IF v_j IS DISTINCT FROM v_ev THEN RAISE EXCEPTION 'DRY_FAIL|an internal failure did not fall back'; END IF;
    -- a throwaway portal identity of my own (everything rolls back)
    INSERT INTO auth.users (id, email, email_confirmed_at) VALUES (up, 'mes9adry-portal@test.local', now());
    INSERT INTO suppliers (legal_name, country, counterparty_type) VALUES ('ZZ-PROBE mes9a dry run supplier', 'SG', 'goods_supplier') RETURNING id INTO s;
    INSERT INTO counterparty_contacts (supplier_id, name, email) VALUES (s, 'ZZ-PROBE dry contact', 'mes9adry-portal@test.local') RETURNING id INTO c;
    INSERT INTO supplier_portal_users (user_id, supplier_id, contact_id) VALUES (up, s, c);
    v_ev := pg_temp.dry_event(up::text); v_j := portal_access_token_hook(v_ev);
    RAISE NOTICE 'DRY|throwaway portal account|0 codes|role in token = %|all other claims unchanged = %',
        v_j #>> '{claims,role}', ((v_j #- '{claims,role}') = (v_ev #- '{claims,role}'));
    IF v_j #>> '{claims,role}' IS DISTINCT FROM 'supplier_portal' OR (v_j #- '{claims,role}') IS DISTINCT FROM (v_ev #- '{claims,role}') THEN
        RAISE EXCEPTION 'DRY_FAIL|the portal account did not get exactly role = supplier_portal'; END IF;
    -- as the portal role, with that account's claims and a session row
    INSERT INTO auth.sessions (id, user_id) VALUES (sid, up);
    PERFORM set_config('request.jwt.claims', jsonb_build_object('sub', up, 'role', 'supplier_portal', 'session_id', sid)::text, true);
    EXECUTE 'SET LOCAL ROLE supplier_portal';
    v := portal_me() #>> '{supplier,name}';
    EXECUTE 'RESET ROLE';
    RAISE NOTICE 'DRY|as supplier_portal: portal_me() → supplier %', v;
    IF v IS DISTINCT FROM 'ZZ-PROBE mes9a dry run supplier' THEN RAISE EXCEPTION 'DRY_FAIL|portal_me as the portal role returned %', v; END IF;
    BEGIN
        EXECUTE 'SET LOCAL ROLE supplier_portal';
        PERFORM count(*) FROM public.suppliers;
        EXECUTE 'RESET ROLE';
        RAISE EXCEPTION 'DRY_FAIL|supplier_portal read the suppliers table';
    EXCEPTION WHEN insufficient_privilege THEN EXECUTE 'RESET ROLE'; RAISE NOTICE 'DRY|as supplier_portal: SELECT FROM suppliers → 42501 (refused)';
    END;
    BEGIN
        EXECUTE 'SET LOCAL ROLE supplier_portal';
        PERFORM current_user_permissions();
        EXECUTE 'RESET ROLE';
        RAISE EXCEPTION 'DRY_FAIL|supplier_portal called current_user_permissions()';
    EXCEPTION WHEN insufficient_privilege THEN EXECUTE 'RESET ROLE'; RAISE NOTICE 'DRY|as supplier_portal: current_user_permissions() → 42501 (refused)';
    END;
    PERFORM set_config('request.jwt.claims', '', true);
    RAISE NOTICE 'DRY|done: % staff role copies + no-role + display + failure path + portal', v_n;
END
$dry$;
ROLLBACK;
SELECT 'AFTER_ROLLBACK|supplier_portal role exists=' || EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'supplier_portal')
       || '|supplier_portal_users exists=' || (to_regclass('public.supplier_portal_users') IS NOT NULL)
       || '|zz-mes9a-dry roles=' || (SELECT count(*) FROM roles WHERE code LIKE 'zz-mes9a-dry-%');
"""
open(sys.argv[2], "w").write(body + "\n\\i db/views/zzz_function_grants.sql\n" + proof)
PY
psql "$DSN" -X -q -v ON_ERROR_STOP=1 -f "$TMP" 2>&1 | grep -E "NOTICE:  (DRY|MES9A)|ERROR|AFTER_ROLLBACK|DRY_FAIL"
rc=${PIPESTATUS[0]}
rm -f "$TMP"
exit "$rc"

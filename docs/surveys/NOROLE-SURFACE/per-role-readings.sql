-- NOROLE-SURFACE build — per-role access reading (steps 3, 4 and 14 of the brief). Rolled back: BEGIN … ROLLBACK, nothing stays.
-- Run: psql "<pooler dsn>" -X -At -v ON_ERROR_STOP=1 -v phase=pre -f docs/surveys/NOROLE-SURFACE/per-role-readings.sql 2>&1
--   (inside the dry run the migration's body is pasted ahead of this file in the same transaction; see db/scripts/2026-10-19-norole-dry-run.sh)
--
-- Identities (all throwaway, all inside this transaction, rolled back with it):
--   * one COPY of each of the 7 live roles held by an account (admin · cco · cfo · cto · finance · gm · warehouse): a new role
--     `zz_noroleprobe_<code>` carrying exactly that role's codes, held by a random uuid that has no auth.users row;
--   * `norole`   — a random uuid holding nothing;
--   * `display`  — a random uuid holding the live `floor_display` role (data.view_floor_board only).
-- No real account, no real role's holders and no pre-existing record or stored file is written. Storage abilities are judged on
-- PROBE object rows inserted by this script (bucket `<b>`, name `zz-noroleprobe/<uuid>`); an existing stored file is only READ
-- (visible count) and its deletability is EVALUATED (the DELETE policies' own expressions run as a SELECT under the session),
-- never deleted. The storage DELETE test sets storage.allow_delete_query for this transaction only, and only probe rows are named.
--
-- Output (NOTICE lines, one per fact):
--   REL|<phase>|<identity>|<object>|rows=<n>|digest=<md5 of the rows it reads>
--   STOR|<phase>|<identity>|<bucket>|visible=<n>|upload=<t/f>|update=<t/f>|delete_orphan=<t/f>|deletable_existing=<n>
--   WHO|<phase>|<identity>|codes=<n>
--   OWN|<phase>|<identity>|user_roles_own=<n>|own_codes=<n>   (its own grant row and its own codes via current_user_permissions)
--   COVER|<phase>|identities=<n>|objects=<n>|buckets=<n>     (raises if any is short — a zero is blindness, not a reading)
BEGIN;
SELECT set_config('noroleprobe.phase', :'phase', true);
DO $read$
DECLARE
    v_phase text := current_setting('noroleprobe.phase');
    v_ids jsonb := '{}'::jsonb;       -- identity -> uuid
    v_role record; v_new uuid; v_uid uuid; v_id text;
    v_obj text; v_n bigint; v_dig text; v_b text; v_probe uuid; v_name text;
    v_up boolean; v_updn int; v_deln int; v_q text; v_del bigint;
    v_objs text[] := ARRAY['user_roles','roles','role_permissions','permissions','metal_prices','metal_price_indices',
                           'pricing_settings','accounts','collection_promise_status'];
    v_nid int := 0; v_nb int := 0; v_own bigint;
BEGIN
    -- ① the identities
    FOR v_role IN SELECT r.id, r.code FROM roles r
                   WHERE r.code IN ('admin','cco','cfo','cto','finance','gm','warehouse')
                     AND EXISTS (SELECT 1 FROM user_roles ur WHERE ur.role_id = r.id AND ur.revoked_at IS NULL)
                   ORDER BY r.code LOOP
        INSERT INTO roles (code, name_en, name_zh, description_en, is_active)
        VALUES ('zz_noroleprobe_' || v_role.code, 'zz noroleprobe ' || v_role.code, 'zz noroleprobe ' || v_role.code, 'NOROLE-SURFACE throwaway copy (rolled back)', true)
        RETURNING id INTO v_new;
        INSERT INTO role_permissions (role_id, permission_code)
        SELECT v_new, rp.permission_code FROM role_permissions rp WHERE rp.role_id = v_role.id;
        v_uid := gen_random_uuid();
        INSERT INTO user_roles (user_id, role_id) VALUES (v_uid, v_new);
        v_ids := v_ids || jsonb_build_object(v_role.code, v_uid);
    END LOOP;
    v_ids := v_ids || jsonb_build_object('norole', gen_random_uuid());
    v_uid := gen_random_uuid();
    INSERT INTO user_roles (user_id, role_id) SELECT v_uid, id FROM roles WHERE code = 'floor_display';
    v_ids := v_ids || jsonb_build_object('display', v_uid);
    IF jsonb_typeof(v_ids) IS DISTINCT FROM 'object' OR (SELECT count(*) FROM jsonb_object_keys(v_ids)) <> 9 THEN
        RAISE EXCEPTION 'PERROLE_COVER|expected 9 identities, got %', v_ids;
    END IF;

    -- ② probe object rows, one per bucket, owned by nobody, named so nothing real can collide (inserted as postgres)
    CREATE TEMP TABLE zz_probe (bucket text, id uuid, name text) ON COMMIT DROP;
    INSERT INTO zz_probe SELECT b.id, gen_random_uuid(), 'zz-noroleprobe/' || gen_random_uuid() FROM storage.buckets b;
    INSERT INTO storage.objects (id, bucket_id, name) SELECT id, bucket, name FROM zz_probe;
    GRANT SELECT ON zz_probe TO authenticated;
    -- my own throwaway rows are excluded from every digest (they are new each run); own user_roles rows are reported apart
    CREATE TEMP TABLE zz_mine (kind text, id uuid) ON COMMIT DROP;
    INSERT INTO zz_mine SELECT 'uid', (v_ids ->> k)::uuid FROM jsonb_object_keys(v_ids) k;
    INSERT INTO zz_mine SELECT 'role', id FROM roles WHERE code LIKE 'zz_noroleprobe_%';
    GRANT SELECT ON zz_mine TO authenticated;

    FOR v_id IN SELECT k FROM jsonb_object_keys(v_ids) k ORDER BY k LOOP
        v_nid := v_nid + 1;
        PERFORM set_config('request.jwt.claims', json_build_object('sub', v_ids ->> v_id, 'role', 'authenticated')::text, true);
        EXECUTE 'SET LOCAL ROLE authenticated';
        RAISE NOTICE 'WHO|%|%|codes=%', v_phase, v_id, COALESCE(array_length(current_user_permissions(), 1), 0);
        FOREACH v_obj IN ARRAY v_objs LOOP
            BEGIN
                EXECUTE format('SELECT count(*), md5(COALESCE(string_agg(t::text, %L ORDER BY t::text), %L)) FROM public.%I t %s', '|', '', v_obj,
                    CASE v_obj WHEN 'user_roles' THEN 'WHERE t.user_id NOT IN (SELECT id FROM zz_mine WHERE kind = ''uid'')'
                               WHEN 'roles' THEN 'WHERE t.id NOT IN (SELECT id FROM zz_mine WHERE kind = ''role'')'
                               WHEN 'role_permissions' THEN 'WHERE t.role_id NOT IN (SELECT id FROM zz_mine WHERE kind = ''role'')'
                               ELSE '' END)
                   INTO v_n, v_dig;
                IF v_obj = 'user_roles' THEN
                    EXECUTE 'SELECT count(*) FROM public.user_roles WHERE user_id = auth.uid()' INTO v_own;
                    RAISE NOTICE 'OWN|%|%|user_roles_own=%|own_codes=%', v_phase, v_id, v_own, COALESCE(array_length(current_user_permissions(), 1), 0);
                END IF;
            EXCEPTION WHEN OTHERS THEN v_n := -1; v_dig := SQLSTATE;
            END;
            RAISE NOTICE 'REL|%|%|%|rows=%|digest=%', v_phase, v_id, v_obj, v_n, v_dig;
        END LOOP;
        FOR v_b, v_probe, v_name IN SELECT bucket, id, name FROM zz_probe ORDER BY bucket LOOP
            -- visible pre-existing files (probe rows excluded)
            SELECT count(*) INTO v_n FROM storage.objects o WHERE o.bucket_id = v_b AND o.name NOT LIKE 'zz-noroleprobe/%';
            -- upload (a fresh probe name, inside a savepoint)
            BEGIN
                INSERT INTO storage.objects (bucket_id, name, owner_id) VALUES (v_b, 'zz-noroleprobe/' || gen_random_uuid(), v_ids ->> v_id);
                v_up := true;
                RAISE EXCEPTION 'zz_undo';
            EXCEPTION WHEN OTHERS THEN
                IF SQLERRM <> 'zz_undo' THEN v_up := false; END IF;
            END;
            -- update the probe row (an object no record points at)
            BEGIN
                UPDATE storage.objects SET metadata = '{"zz":1}'::jsonb WHERE id = v_probe;
                GET DIAGNOSTICS v_updn = ROW_COUNT;
                RAISE EXCEPTION 'zz_undo';
            EXCEPTION WHEN OTHERS THEN
                IF SQLERRM <> 'zz_undo' THEN v_updn := 0; END IF;
            END;
            -- delete the probe row (an orphan)
            BEGIN
                PERFORM set_config('storage.allow_delete_query', 'true', true);
                DELETE FROM storage.objects WHERE id = v_probe;
                GET DIAGNOSTICS v_deln = ROW_COUNT;
                RAISE EXCEPTION 'zz_undo';
            EXCEPTION WHEN OTHERS THEN
                IF SQLERRM <> 'zz_undo' THEN v_deln := 0; END IF;
            END;
            PERFORM set_config('storage.allow_delete_query', 'false', true);
            -- existing files this session's DELETE policies would let it remove — evaluated, never executed
            SELECT string_agg('(' || pg_get_expr(p.polqual, p.polrelid) || ')', ' OR ') INTO v_q
              FROM pg_policy p WHERE p.polrelid = 'storage.objects'::regclass AND p.polcmd IN ('d', '*')
               AND (p.polroles = '{0}' OR 'authenticated'::regrole = ANY (p.polroles));
            IF v_q IS NULL THEN v_del := 0;
            ELSE
                EXECUTE format('SELECT count(*) FROM storage.objects objects WHERE objects.bucket_id = %L AND objects.name NOT LIKE %L AND (%s)',
                               v_b, 'zz-noroleprobe/%', v_q) INTO v_del;
            END IF;
            RAISE NOTICE 'STOR|%|%|%|visible=%|upload=%|update=%|delete_orphan=%|deletable_existing=%',
                v_phase, v_id, v_b, v_n, v_up, (v_updn = 1), (v_deln = 1), v_del;
        END LOOP;
        EXECUTE 'RESET ROLE';
    END LOOP;
    SELECT count(*) INTO v_nb FROM storage.buckets;
    IF v_nid <> 9 OR v_nb < 19 THEN
        RAISE EXCEPTION 'PERROLE_COVER|identities=% buckets=% — a short reading is blindness, not a reading', v_nid, v_nb;
    END IF;
    RAISE NOTICE 'COVER|%|identities=%|objects=%|buckets=%', v_phase, v_nid, array_length(v_objs, 1), v_nb;
END
$read$;
ROLLBACK;

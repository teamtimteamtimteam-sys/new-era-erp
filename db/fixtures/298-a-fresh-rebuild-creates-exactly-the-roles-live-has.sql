-- ═══════════════════════════════════════════════════════════════════════════
-- fixture 298 —— 全新重建出来的角色,正是线上那 11 个,逐码相同(GOLIVE-1 第 5 行,Tim 2026-10-20 d2 #27 · 2026-10-29 Q2–Q5)
-- ═══════════════════════════════════════════════════════════════════════════
-- 【钉的事】重建库的引导(db/tables/roles.sql · role_permissions.sql)与 db/seeds/eleven-roles-2026-10-30.sql 逐个相同 ——
--   而 db/live-fixtures/298 对着线上核对同一份。两支都绿 = "重建出来的角色就是线上的角色"(ROLE1-BOOTSTRAP-MISSING-ROLES 关闭)。
--   SET     角色的集合恰好是那 11 个(hr · procurement · sales 不在;cfo · cco · cto 在)
--   SAME    每一个角色的码集合与快照逐个相同(多一个、少一个都红,点名角色与码)
--   SHAPE   auditor(Q2):18 个模块查看码全在,没有一个 .edit、没有一个 action.*,不含 banking · pay · identity · health · reviews;
--           employee(Q3):0 个码;operations(Q4):停用并软删(与线上同);admin:目录里的每一个码
--   INJECT  ★ 故障注入(每次都跑):子事务里从 auditor 拿掉 module.quality.view,SAME 的判据必须点出这一个码;子事务回滚
-- 以 postgres 读基表(rolbypassrls,基表 —— 真行数)。重建库里没有任何 user_roles,所以这里只比角色与授权,不比持有人。
-- ═══════════════════════════════════════════════════════════════════════════
\ir ../seeds/eleven-roles-2026-10-30.sql
BEGIN;
SELECT set_config('golive1.eleven_roles', :'eleven_roles', true) \g /dev/null

CREATE FUNCTION pg_temp.f298_diff(snap jsonb) RETURNS text
LANGUAGE plpgsql AS $f$
DECLARE k text; v_extra text; v_missing text; v_out text := '';
BEGIN
    FOR k IN SELECT jsonb_object_keys(snap) LOOP
        SELECT string_agg(c, ',' ORDER BY c) INTO v_extra FROM (
            SELECT rp.permission_code AS c FROM role_permissions rp JOIN roles r ON r.id = rp.role_id WHERE r.code = k
            EXCEPT SELECT jsonb_array_elements_text(snap -> k)) z;
        SELECT string_agg(c, ',' ORDER BY c) INTO v_missing FROM (
            SELECT jsonb_array_elements_text(snap -> k) AS c
            EXCEPT SELECT rp.permission_code FROM role_permissions rp JOIN roles r ON r.id = rp.role_id WHERE r.code = k) z;
        IF v_extra IS NOT NULL OR v_missing IS NOT NULL THEN
            v_out := v_out || format('%s: extra [%s] missing [%s]; ', k, coalesce(v_extra, ''), coalesce(v_missing, ''));
        END IF;
    END LOOP;
    RETURN NULLIF(v_out, '');
END;
$f$;

DO $f298$
DECLARE
    snap jsonb := current_setting('golive1.eleven_roles')::jsonb;
    v text;
    n int;
BEGIN
    -- SET
    SELECT string_agg(code, ',' ORDER BY code) INTO v FROM roles;
    IF v IS DISTINCT FROM (SELECT string_agg(k, ',' ORDER BY k) FROM jsonb_object_keys(snap) k) THEN
        RAISE EXCEPTION 'FIXTURE 298 SET: the rebuild creates roles [%], the snapshot names [%]', v,
            (SELECT string_agg(k, ',' ORDER BY k) FROM jsonb_object_keys(snap) k);
    END IF;
    IF (SELECT count(*) FROM jsonb_object_keys(snap)) <> 11 THEN
        RAISE EXCEPTION 'FIXTURE 298 SET: the snapshot does not hold eleven roles';
    END IF;
    -- SAME
    v := pg_temp.f298_diff(snap);
    IF v IS NOT NULL THEN
        RAISE EXCEPTION 'FIXTURE 298 SAME: the rebuild bootstrap differs from db/seeds/eleven-roles-2026-10-30.sql — %', v;
    END IF;
    -- SHAPE
    IF EXISTS (SELECT 1 FROM permissions p WHERE p.code LIKE 'module.%.view' AND NOT (snap -> 'auditor') ? p.code) THEN
        RAISE EXCEPTION 'FIXTURE 298 SHAPE: auditor lacks a module view code';
    END IF;
    IF EXISTS (SELECT 1 FROM jsonb_array_elements_text(snap -> 'auditor') c
                WHERE c LIKE '%.edit' OR c LIKE 'action.%' OR c LIKE 'module.%.view_all'
                   OR c IN ('data.view_banking', 'data.view_pay', 'data.view_identity', 'data.view_health', 'data.view_reviews')) THEN
        RAISE EXCEPTION 'FIXTURE 298 SHAPE: auditor holds a write code or one of the five excluded data codes';
    END IF;
    IF jsonb_array_length(snap -> 'employee') <> 0 OR jsonb_array_length(snap -> 'auditor') <> 25 THEN
        RAISE EXCEPTION 'FIXTURE 298 SHAPE: employee % codes (want 0), auditor % (want 25)', jsonb_array_length(snap -> 'employee'), jsonb_array_length(snap -> 'auditor');
    END IF;
    IF (SELECT is_active OR deleted_at IS NULL FROM roles WHERE code = 'operations') IS DISTINCT FROM false
       OR EXISTS (SELECT 1 FROM roles WHERE code <> 'operations' AND (NOT is_active OR deleted_at IS NOT NULL)) THEN
        RAISE EXCEPTION 'FIXTURE 298 SHAPE: operations should be inactive and soft-deleted, every other role active — as on live';
    END IF;
    SELECT count(*) INTO n FROM permissions p WHERE NOT (snap -> 'admin') ? p.code;
    IF n <> 0 THEN RAISE EXCEPTION 'FIXTURE 298 SHAPE: admin lacks % catalogue code(s)', n; END IF;
    -- INJECT
    BEGIN
        DELETE FROM role_permissions rp USING roles r WHERE r.id = rp.role_id AND r.code = 'auditor' AND rp.permission_code = 'module.quality.view';
        v := pg_temp.f298_diff(snap);
        IF v IS NULL OR v NOT LIKE '%auditor: extra [] missing [module.quality.view]%' THEN
            RAISE EXCEPTION 'FIXTURE 298 INJECT: removing auditor''s module.quality.view was not named by SAME (got %)', v;
        END IF;
        RAISE EXCEPTION 'f298 injection ok';
    EXCEPTION WHEN OTHERS THEN
        IF SQLERRM <> 'f298 injection ok' THEN RAISE; END IF;
    END;
    IF pg_temp.f298_diff(snap) IS NOT NULL THEN RAISE EXCEPTION 'FIXTURE 298 INJECT: the injection did not roll back'; END IF;
    RAISE NOTICE 'FIXTURE 298 全部通过: 重建库建出线上那 11 个角色、逐码同快照(SET · SAME);auditor 25 码只读、employee 0 码、operations 停用、admin 全码(SHAPE);拿掉一个码被点名(INJECT)';
END
$f298$;
ROLLBACK;

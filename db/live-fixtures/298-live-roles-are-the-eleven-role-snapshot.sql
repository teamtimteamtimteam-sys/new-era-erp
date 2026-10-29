-- ═══════════════════════════════════════════════════════════════════════════
-- live fixture 298 —— 线上的角色正是 db/seeds/eleven-roles-2026-10-29.sql 那 11 个,逐码相同(GOLIVE-1 第 5 行)
-- ═══════════════════════════════════════════════════════════════════════════
-- db/fixtures/298 证"重建 = 快照";这一支证"线上 = 快照"。由 db/gate.py 的整门对着线上跑(只读;--offline 不跑并点名)。
-- 线上改了角色(界面上加减一个码是正常的),这一支就红 —— 同一个提交重取一份新日期的快照并改两支的 \ir。
-- 以 postgres 读基表 roles / role_permissions(rolbypassrls = true,基表)。
-- ═══════════════════════════════════════════════════════════════════════════
\ir ../seeds/eleven-roles-2026-10-29.sql
BEGIN READ ONLY;
SELECT set_config('golive1.eleven_roles', :'eleven_roles', true) \g /dev/null
DO $live$
DECLARE
    snap jsonb := current_setting('golive1.eleven_roles')::jsonb;
    k text; v text; v_extra text; v_missing text;
BEGIN
    SELECT string_agg(code, ',' ORDER BY code) INTO v FROM roles;
    IF v IS DISTINCT FROM (SELECT string_agg(x, ',' ORDER BY x) FROM jsonb_object_keys(snap) x) THEN
        RAISE EXCEPTION 'LIVE FIXTURE 298 SET: live has roles [%]', v;
    END IF;
    FOR k IN SELECT jsonb_object_keys(snap) LOOP
        SELECT string_agg(c, ',' ORDER BY c) INTO v_extra FROM (
            SELECT rp.permission_code AS c FROM role_permissions rp JOIN roles r ON r.id = rp.role_id WHERE r.code = k
            EXCEPT SELECT jsonb_array_elements_text(snap -> k)) z;
        SELECT string_agg(c, ',' ORDER BY c) INTO v_missing FROM (
            SELECT jsonb_array_elements_text(snap -> k) AS c
            EXCEPT SELECT rp.permission_code FROM role_permissions rp JOIN roles r ON r.id = rp.role_id WHERE r.code = k) z;
        IF v_extra IS NOT NULL OR v_missing IS NOT NULL THEN
            RAISE EXCEPTION 'LIVE FIXTURE 298 SAME: role % on live differs from db/seeds/eleven-roles-2026-10-29.sql — live has extra [%], live lacks [%]',
                k, coalesce(v_extra, ''), coalesce(v_missing, '');
        END IF;
    END LOOP;
    IF (SELECT is_active OR deleted_at IS NULL FROM roles WHERE code = 'operations') IS DISTINCT FROM false
       OR EXISTS (SELECT 1 FROM roles WHERE code <> 'operations' AND (NOT is_active OR deleted_at IS NOT NULL)) THEN
        RAISE EXCEPTION 'LIVE FIXTURE 298 SHAPE: operations should be inactive and soft-deleted, every other role active';
    END IF;
END
$live$;
ROLLBACK;

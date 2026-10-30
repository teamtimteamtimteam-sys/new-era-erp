-- ═══════════════════════════════════════════════════════════════════════════
-- live fixture 297 —— fixture 297 计时用的七个角色读码快照,仍然与线上一字不差(CHAIN-WALK-COST,Tim 2026-10-28 Q4)
-- ═══════════════════════════════════════════════════════════════════════════
-- 【为什么】db/fixtures/297 在一年体量的本地重建上以七个角色计时 —— 而重建库的引导里没有 cco / cfo / cto、finance 少三个码,
--   所以那支 fixture 带着一份【有日期的快照】(db/seeds/seven-roles-2026-10-30.sql)。快照会过期:线上改了一个角色的码,
--   那支 fixture 计的就不再是线上那个角色。这一支由 db/gate.py 的整门对着【线上】跑(只读;--offline 不跑并点名),
--   不一样就红 —— 改了角色,就同一个提交重取一份快照(新日期的文件)并改 fixture 297 的 \ir。
-- 以 postgres 读基表 roles / role_permissions(rolbypassrls = true,基表 —— 读到的是真行数,不是一次权限答复)。
-- 断言:
--   SAME     七个角色每一个的读码集合与快照逐个相同(多一个、少一个都红,点名角色与码)
--   SUBJECT  七个角色在线上都存在、都启用(否则快照里的名字是空名字)
-- ═══════════════════════════════════════════════════════════════════════════
\ir ../seeds/seven-roles-2026-10-30.sql
BEGIN READ ONLY;
SELECT set_config('cwc.seven_roles', :'seven_roles', true) \g /dev/null
DO $live$
DECLARE
    snap jsonb := current_setting('cwc.seven_roles')::jsonb;
    k    text;
    v_live jsonb;
    v_extra text;
    v_missing text;
BEGIN
    IF snap IS NULL OR (SELECT count(*) FROM jsonb_object_keys(snap)) <> 7 THEN
        RAISE EXCEPTION 'LIVE FIXTURE 297 SUBJECT: the snapshot does not hold seven roles';
    END IF;
    FOR k IN SELECT jsonb_object_keys(snap) LOOP
        IF NOT EXISTS (SELECT 1 FROM roles r WHERE r.code = k AND r.is_active AND r.deleted_at IS NULL) THEN
            RAISE EXCEPTION 'LIVE FIXTURE 297 SUBJECT: role % is not an active role on live', k;
        END IF;
        SELECT string_agg(c, ',' ORDER BY c) INTO v_extra FROM (
            SELECT rp.permission_code AS c FROM role_permissions rp JOIN roles r ON r.id = rp.role_id WHERE r.code = k
            EXCEPT SELECT jsonb_array_elements_text(snap -> k)) z;
        SELECT string_agg(c, ',' ORDER BY c) INTO v_missing FROM (
            SELECT jsonb_array_elements_text(snap -> k) AS c
            EXCEPT SELECT rp.permission_code FROM role_permissions rp JOIN roles r ON r.id = rp.role_id WHERE r.code = k) z;
        IF v_extra IS NOT NULL OR v_missing IS NOT NULL THEN
            RAISE EXCEPTION 'LIVE FIXTURE 297 SAME: role % on live differs from db/seeds/seven-roles-2026-10-30.sql — live has extra [%], live lacks [%]',
                k, coalesce(v_extra, ''), coalesce(v_missing, '');
        END IF;
    END LOOP;
END
$live$;
ROLLBACK;

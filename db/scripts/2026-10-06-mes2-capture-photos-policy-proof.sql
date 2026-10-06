-- db/scripts/2026-10-06-mes2-capture-photos-policy-proof.sql
-- MES-2 · 私有桶 capture-photos 与地磅单照片登记行的【逐权限证明】—— 整支回滚,一行都不留。
--
-- 跑法(ON_ERROR_STOP 是判据的一半):
--     psql -X -v ON_ERROR_STOP=1 -f db/scripts/2026-10-06-mes2-capture-photos-policy-proof.sql
--     故障注入:加 -v inject=1 —— 读策略被换成"只看桶"的放行版,C4(没有收货/物流查看码的人读得到)必须当场 RAISE。
--
-- 【为什么它不住在 db/fixtures/】桶与它的策略不在镜像里,重建库没有 storage 架构(AGENTS.md「存储桶与它的策略不在镜像里」;
--   先例 db/scripts/2026-09-05-ui1d-avatar-policy-proof.sql)。所以它对着线上跑,包在一笔回滚的事务里。
--
-- 【身份,按"权限"而不是按"人"】委托书:"upload, read and withdraw a photo in capture-photos as each permission"。
--   ① action.confirm_capture(+ 收货与物流查看)—— fusheng@(warehouse,真账号):传、登记、读、撤下
--   ② 只有 module.inbound.view —— 本事务里造的探针角色 + 一个凭空的 uuid:读得到,传不进
--   ③ 只有 module.logistics.view —— 同上:读得到,传不进
--   ④ 收货与物流都看得见、但不持确认码 —— tim@(cfo,真账号):读得到,传不进、登记不了、撤不了
--   ⑤ 一个码都没有 —— 凭空的 uuid:读不到(桶与登记行都是 0 行),传不进
--   凭空的 uuid 不是任何人的账号:user_roles.user_id 没有外键,auth.uid() 读的是 request.jwt.claims —— 【不建任何账号】。
--   探针角色与那两条授权随 ROLLBACK 消失。七个真账号的角色一条都不碰。
-- 【断言一律 RAISE】被策略挡住的读不报错、只是少几行(AGENTS.md)。所以每一格都数行数并在不符时 RAISE。
\set ON_ERROR_STOP on
BEGIN;
SET LOCAL statement_timeout = '120s';

\if :{?inject}
DROP POLICY "capture-photos read by inbound or logistics view" ON storage.objects;
CREATE POLICY "capture-photos read by inbound or logistics view"
    ON storage.objects AS PERMISSIVE FOR SELECT TO authenticated
    USING (bucket_id = 'capture-photos'::text);   -- ← 权限判据被拿掉了,这就是注入
\echo '★★ 注入已生效:capture-photos 的读策略 = 放行版(只看桶)★★'
\endif

CREATE TEMP TABLE pp_obj (uid uuid, nm text);

CREATE FUNCTION pg_temp.pp_as(p_user uuid) RETURNS void LANGUAGE sql AS $f$
    SELECT set_config('request.jwt.claims', format('{"sub":"%s","role":"authenticated"}', p_user), true) $f$;
-- 以某人的身份往桶里放一个对象:成功回 'OK',被 RLS 拒回 '42501',别的错回原文
CREATE FUNCTION pg_temp.pp_put(p_user uuid, p_name text) RETURNS text LANGUAGE plpgsql AS $f$
DECLARE v text;
BEGIN
    PERFORM pg_temp.pp_as(p_user);
    EXECUTE 'SET LOCAL ROLE authenticated';
    BEGIN
        INSERT INTO storage.objects (bucket_id, name, owner, owner_id, metadata)
        VALUES ('capture-photos', p_name, p_user, p_user::text, '{"mimetype":"image/jpeg","size":2048}'::jsonb);
        v := 'OK';
    EXCEPTION WHEN insufficient_privilege THEN v := '42501';
              WHEN OTHERS THEN v := SQLERRM;
    END;
    EXECUTE 'RESET ROLE';
    RETURN v;
END $f$;
-- 以某人的身份数:桶里那个对象几行 · 登记行几行
CREATE FUNCTION pg_temp.pp_see(p_user uuid, p_name text, p_ticket uuid) RETURNS text LANGUAGE plpgsql AS $f$
DECLARE o int; r int;
BEGIN
    PERFORM pg_temp.pp_as(p_user);
    EXECUTE 'SET LOCAL ROLE authenticated';
    SELECT count(*) INTO o FROM storage.objects WHERE bucket_id = 'capture-photos' AND name = p_name;
    SELECT count(*) INTO r FROM weighbridge_ticket_photos WHERE ticket_id = p_ticket;
    EXECUTE 'RESET ROLE';
    RETURN o || '/' || r;
END $f$;
-- 以某人的身份跑一句;成功回 'OK',失败回错误原文
CREATE FUNCTION pg_temp.pp_try(p_user uuid, p_sql text) RETURNS text LANGUAGE plpgsql AS $f$
DECLARE v text;
BEGIN
    PERFORM pg_temp.pp_as(p_user);
    EXECUTE 'SET LOCAL ROLE authenticated';
    BEGIN EXECUTE p_sql; v := 'OK';
    EXCEPTION WHEN OTHERS THEN v := SQLERRM; END;
    EXECUTE 'RESET ROLE';
    RETURN v;
END $f$;

DO $proof$
DECLARE
    u_wh  uuid := (SELECT id FROM auth.users WHERE email = 'fusheng@evoltrya.test');
    u_cfo uuid := (SELECT id FROM auth.users WHERE email = 'tim@evoltrya.test');
    u_in  uuid := '00000000-0000-4000-8000-00000000a201';   -- 凭空:只有 module.inbound.view
    u_log uuid := '00000000-0000-4000-8000-00000000a202';   -- 凭空:只有 module.logistics.view
    u_no  uuid := '00000000-0000-4000-8000-00000000a203';   -- 凭空:一个码都没有
    r_in uuid; r_log uuid; tk uuid; wb uuid; ph uuid; nm text; v text; n int;
BEGIN
    IF u_wh IS NULL OR u_cfo IS NULL THEN RAISE EXCEPTION '[photo-proof] setup: a named account is missing'; END IF;
    PERFORM 1 FROM storage.buckets WHERE id = 'capture-photos' AND NOT public AND file_size_limit = 10485760
                                     AND allowed_mime_types = ARRAY['image/jpeg', 'image/png', 'image/webp'];
    IF NOT FOUND THEN RAISE EXCEPTION '[photo-proof] setup: bucket capture-photos is missing or not private / 10 MB / three image types'; END IF;
    IF (SELECT count(*) FROM pg_policies WHERE schemaname = 'storage' AND tablename = 'objects' AND policyname LIKE 'capture-photos%') <> 2 THEN
        RAISE EXCEPTION '[photo-proof] setup: expected exactly 2 capture-photos policies (read, upload) — no update, no delete'; END IF;

    -- 探针角色(本事务里),各给一个码,授给凭空的 uuid
    INSERT INTO roles (code, name_en, name_zh, is_system) VALUES ('zz_mes2_inbound_only', 'MES-2 proof: inbound view only', 'MES-2 证明:只看收货', false) RETURNING id INTO r_in;
    INSERT INTO roles (code, name_en, name_zh, is_system) VALUES ('zz_mes2_logistics_only', 'MES-2 proof: logistics view only', 'MES-2 证明:只看物流', false) RETURNING id INTO r_log;
    INSERT INTO role_permissions (role_id, permission_code) VALUES (r_in, 'module.inbound.view'), (r_log, 'module.logistics.view');
    INSERT INTO user_roles (user_id, role_id) VALUES (u_in, r_in), (u_log, r_log);
    PERFORM pg_temp.pp_as(u_in);  IF NOT (has_permission('module.inbound.view') AND NOT has_permission('module.logistics.view')) THEN RAISE EXCEPTION '[photo-proof] setup: inbound-only identity'; END IF;
    PERFORM pg_temp.pp_as(u_log); IF NOT (has_permission('module.logistics.view') AND NOT has_permission('module.inbound.view')) THEN RAISE EXCEPTION '[photo-proof] setup: logistics-only identity'; END IF;
    PERFORM pg_temp.pp_as(u_no);  IF cardinality(current_user_permissions()) <> 0 THEN RAISE EXCEPTION '[photo-proof] setup: the no-code identity holds codes'; END IF;
    PERFORM pg_temp.pp_as(u_cfo); IF has_permission('action.confirm_capture') THEN RAISE EXCEPTION '[photo-proof] setup: tim@ is expected NOT to hold action.confirm_capture'; END IF;
    PERFORM pg_temp.pp_as(u_wh);  IF NOT has_permission('action.confirm_capture') THEN RAISE EXCEPTION '[photo-proof] setup: fusheng@ is expected to hold action.confirm_capture'; END IF;

    -- 一张本事务里的地磅单(手工一磅,不选仪器,开新单)
    v := pg_temp.pp_try(u_wh, $q$SELECT submit_manual_capture('weighing', '{"weight_kg": 9000}'::jsonb, NULL, NULL, NULL, '{"new_ticket": {"direction": "inbound", "vehicle_reg": "ZZ PHOTO"}}'::jsonb)$q$);
    IF v <> 'OK' THEN RAISE EXCEPTION '[photo-proof] setup: the ticket: %', v; END IF;
    SELECT t.id INTO tk FROM weighbridge_tickets t WHERE t.vehicle_reg = 'ZZ PHOTO' ORDER BY t.created_at DESC LIMIT 1;
    nm := tk::text || '/' || gen_random_uuid()::text || '-front.jpg';

    -- ① 传:只有持确认码的人传得进
    FOREACH v IN ARRAY ARRAY[pg_temp.pp_put(u_cfo, tk::text || '/c-cfo.jpg'), pg_temp.pp_put(u_in, tk::text || '/c-in.jpg'),
                             pg_temp.pp_put(u_log, tk::text || '/c-log.jpg'), pg_temp.pp_put(u_no, tk::text || '/c-no.jpg')] LOOP
        IF v <> '42501' THEN RAISE EXCEPTION '[photo-proof · C1] someone without action.confirm_capture uploaded (got %)', v; END IF;
    END LOOP;
    v := pg_temp.pp_put(u_wh, nm);
    IF v <> 'OK' THEN RAISE EXCEPTION '[photo-proof · C1] fusheng@ (action.confirm_capture) could not upload: %', v; END IF;
    RAISE NOTICE 'PHOTO C1 upload: fusheng@ OK · tim@ 42501 · inbound-only 42501 · logistics-only 42501 · no-code 42501';

    -- ② 登记:同一个码;路径要在这张单下面
    v := pg_temp.pp_try(u_cfo, format($q$SELECT record_ticket_photo(%L, %L, 'front.jpg', 'image/jpeg', 2048)$q$, tk, nm));
    IF v NOT LIKE 'PERMISSION_DENIED|action.confirm_capture%' THEN RAISE EXCEPTION '[photo-proof · C2] tim@ recorded a photo: %', v; END IF;
    v := pg_temp.pp_try(u_wh, format($q$SELECT record_ticket_photo(%L, %L, 'x.jpg', 'image/jpeg', 2048)$q$, tk, 'elsewhere/x.jpg'));
    IF v <> 'TICKET_PHOTO_PATH_INVALID' THEN RAISE EXCEPTION '[photo-proof · C2] a path outside the ticket: %', v; END IF;
    v := pg_temp.pp_try(u_wh, format($q$SELECT record_ticket_photo(%L, %L, 'front.jpg', 'image/jpeg', 2048)$q$, tk, nm));
    IF v <> 'OK' THEN RAISE EXCEPTION '[photo-proof · C2] fusheng@ could not record the photo: %', v; END IF;
    SELECT id INTO ph FROM weighbridge_ticket_photos WHERE file_path = nm;
    RAISE NOTICE 'PHOTO C2 record: fusheng@ OK · tim@ PERMISSION_DENIED · path outside the ticket TICKET_PHOTO_PATH_INVALID';

    -- ③ 读:对象 / 登记行,按权限
    FOR v, n IN SELECT * FROM (VALUES ('fusheng@ (warehouse)', 1), ('tim@ (cfo)', 2), ('inbound-only', 3), ('logistics-only', 4)) x LOOP
        DECLARE got text := pg_temp.pp_see((ARRAY[u_wh, u_cfo, u_in, u_log])[n], nm, tk);
        BEGIN
            IF got <> '1/1' THEN RAISE EXCEPTION '[photo-proof · C3] % should read the object and its record, got %', v, got; END IF;
        END;
    END LOOP;
    v := pg_temp.pp_see(u_no, nm, tk);
    IF v <> '0/0' THEN RAISE EXCEPTION '[photo-proof · C4] a reader without inbound or logistics view read the photo (object/record = %)', v; END IF;
    RAISE NOTICE 'PHOTO C3/C4 read (object/record): fusheng@ 1/1 · tim@ 1/1 · inbound-only 1/1 · logistics-only 1/1 · no-code 0/0 (refused)';

    -- ④ 撤下:持确认码的人,理由必填;行与对象都留着
    v := pg_temp.pp_try(u_cfo, format($q$SELECT withdraw_ticket_photo(%L, 'wrong truck')$q$, ph));
    IF v NOT LIKE 'PERMISSION_DENIED|action.confirm_capture%' THEN RAISE EXCEPTION '[photo-proof · C5] tim@ withdrew a photo: %', v; END IF;
    v := pg_temp.pp_try(u_wh, format($q$SELECT withdraw_ticket_photo(%L, '  ')$q$, ph));
    IF v <> 'TICKET_PHOTO_WITHDRAW_REASON_REQUIRED' THEN RAISE EXCEPTION '[photo-proof · C5] a blank reason: %', v; END IF;
    v := pg_temp.pp_try(u_wh, format($q$SELECT withdraw_ticket_photo(%L, 'wrong truck')$q$, ph));
    IF v <> 'OK' THEN RAISE EXCEPTION '[photo-proof · C5] fusheng@ could not withdraw: %', v; END IF;
    IF (SELECT withdrawn_at IS NULL OR withdraw_reason IS DISTINCT FROM 'wrong truck' FROM weighbridge_ticket_photos WHERE id = ph) THEN
        RAISE EXCEPTION '[photo-proof · C5] the withdrawal did not land on the record'; END IF;
    IF pg_temp.pp_see(u_wh, nm, tk) <> '1/1' THEN RAISE EXCEPTION '[photo-proof · C5] the withdrawn photo''s object or record disappeared'; END IF;
    RAISE NOTICE 'PHOTO C5 withdraw: fusheng@ OK (reason kept, object and record stay) · tim@ PERMISSION_DENIED · blank reason refused';

    INSERT INTO pp_obj VALUES (u_wh, nm);
    RAISE NOTICE '[photo-proof] C1–C5 通过';
END
$proof$;

-- ⑤ 桶里不能改、不能删 —— 连持确认码的人也不行(没有 UPDATE / DELETE 策略)。
--    平台那条语句级 protect_delete 会在策略之前开火,所以这一格在 replica 下量【我们的策略】(UI-1d 的同一个做法)。
--    ★ 线上实测:set_config('session_replication_role', …) 在 DO 块里被拒("permission denied to set parameter"),
--      顶层的 SET LOCAL 可以 —— 所以这一格单独一个块、放在最后:前面 C1–C5 跑的时候,本仓库自己的守卫触发器全开着。
SET LOCAL session_replication_role = replica;
DO $c6$
DECLARE o record; n int;
BEGIN
    SELECT * INTO o FROM pp_obj;
    PERFORM pg_temp.pp_as(o.uid);
    EXECUTE 'SET LOCAL ROLE authenticated';
    UPDATE storage.objects SET metadata = '{"mimetype":"image/jpeg","size":1}'::jsonb WHERE bucket_id = 'capture-photos' AND name = o.nm;
    GET DIAGNOSTICS n = ROW_COUNT;
    IF n <> 0 THEN EXECUTE 'RESET ROLE'; RAISE EXCEPTION '[photo-proof · C6] fusheng@ updated a bucket object (% rows)', n; END IF;
    DELETE FROM storage.objects WHERE bucket_id = 'capture-photos' AND name = o.nm;
    GET DIAGNOSTICS n = ROW_COUNT;
    IF n <> 0 THEN EXECUTE 'RESET ROLE'; RAISE EXCEPTION '[photo-proof · C6] fusheng@ deleted a bucket object (% rows)', n; END IF;
    EXECUTE 'RESET ROLE';
    IF (SELECT count(*) FROM storage.objects WHERE bucket_id = 'capture-photos' AND name = o.nm) <> 1 THEN
        RAISE EXCEPTION '[photo-proof · C6] the object is gone'; END IF;
    RAISE NOTICE 'PHOTO C6 bucket object: update 0 rows · delete 0 rows (fusheng@; policy measured with the platform trigger out of the way)';
    RAISE NOTICE '[photo-proof] 全部通过:C1 C2 C3 C4 C5 C6 —— ROLLBACK 之后一行都不留';
END
$c6$;

ROLLBACK;

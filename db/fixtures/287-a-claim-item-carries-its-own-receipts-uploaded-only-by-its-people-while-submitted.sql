-- db/fixtures/287-a-claim-item-carries-its-own-receipts-uploaded-only-by-its-people-while-submitted.sql
-- ═══════════════════════════════════════════════════════════════════════════
-- CLAIM-RECEIPTS-1(Tim 2026-10-21,Step 0 Q1 · Q4 · Q5 · Q6 · Q7 · Q9 · Q10 · Q13):报销单的每一笔带它自己的收据。
--
--   A  BEGIN    按名拒,一个字节都不登记:这一笔不存在 · 不是这张单的人(另一名员工;一个只持 module.finance.view 的读者)·
--               HEIC / Word(TYPE_NOT_ACCEPTED)· 空文件 · 超过 10 MB · 文件名空 · 单已撤回(CLAIM_NOT_SUBMITTED)·
--               整个项目的存储到了 900 MB(STORAGE_FULL)。过了:员工本人与替他提单的人(Q4)各登记一行 uploading,路径在单 / 笔之下。
--   B  UPLOAD   存储策略(真的 RLS,authenticated):登记的人往登记的那条路径传得进;别的路径、别人、十分钟以前登记的、单已被决定的,
--               一律传不进;没有人改得动、删得掉 claim-receipts 里的一个对象(Q5)。
--   C  FINISH   对象不在 → NOT_STORED;大小对不上 → MISMATCH;对得上 → attached;再 finish 一次 → NOT_UPLOADING;别人 finish 不了;
--               没传成 → abandon。
--   D  READ     (Q6 · Q7)module.finance.view 读全部(行与对象);员工与提单人读自己那张单的;另一名员工读 0;
--               被拿掉(removed)的:员工 0,财务照样读得到。
--   E  REMOVE   (Q5)submitted 时员工拿得掉一份(谁、何时记在行上,对象留在桶里);别人拿不掉;决定之后谁都拿不掉。
--   F  DECIDE   (Q13)逐笔:第 2 笔只有一份还在传的、一份没传成的、一份被拿掉的 → EXPENSE_CLAIM_NO_EVIDENCE|单号|2;
--               给它一份 attached 的 → 批得过。一笔几份文件都行(Q9)。
--   G  AFTER    批准之后:begin / finish(上传途中被批)/ remove 都按名拒(CLAIM_NOT_SUBMITTED)。
--   H  GUARD    行只往前走:attached → uploading、改路径、删行 → CLAIM_RECEIPT_IMMUTABLE。
--   I  SHAPE    整张单的附件那条路不在了:finance_attachments 没有 claim_id、expense_claim_status 没有 has_receipt;
--               两条审计记录挂的是 expense_claim_receipts。
-- 前提:db/gate.py 已把 storage 桩与 db/storage/buckets-and-policies.sql 装进这个重建库(没有 claim-receipts 桶 → 按名红)。
-- 自带数据(README 第 2 条);GST、期间锁、V39 自己设(第 4/5 条)。
-- ═══════════════════════════════════════════════════════════════════════════
BEGIN;
SET LOCAL statement_timeout = '300s';

CREATE FUNCTION pg_temp.f287_as(p_user uuid) RETURNS void
LANGUAGE sql AS $f$
    SELECT set_config('request.jwt.claims',
                      CASE WHEN p_user IS NULL THEN '' ELSE format('{"sub":"%s","role":"authenticated"}', p_user) END, true)
$f$;

-- 以 p_user 的会话(authenticated + JWT,真的 RLS)跑一句,回影响 / 读到的行数;被拒回 -1
CREATE FUNCTION pg_temp.f287_rc(p_user uuid, p_sql text) RETURNS bigint
LANGUAGE plpgsql AS $f$
DECLARE v bigint;
BEGIN
    PERFORM pg_temp.f287_as(p_user);
    EXECUTE 'SET LOCAL ROLE authenticated';
    BEGIN
        IF p_sql ~* '^\s*select' THEN EXECUTE p_sql INTO v;
        ELSE EXECUTE p_sql; GET DIAGNOSTICS v = ROW_COUNT; END IF;
    EXCEPTION WHEN OTHERS THEN v := -1; END;
    EXECUTE 'RESET ROLE';
    PERFORM pg_temp.f287_as(NULL);
    RETURN v;
END;
$f$;

-- 以 p_user 调一句(函数是属主权限,不必切角色),回结果或 'ERR|<错>'
CREATE FUNCTION pg_temp.f287_call(p_user uuid, p_sql text) RETURNS text
LANGUAGE plpgsql AS $f$
DECLARE v text;
BEGIN
    PERFORM pg_temp.f287_as(p_user);
    BEGIN EXECUTE p_sql INTO v; EXCEPTION WHEN OTHERS THEN v := 'ERR|' || SQLERRM; END;
    PERFORM pg_temp.f287_as(NULL);
    RETURN COALESCE(v, '<null>');
END;
$f$;

DO $f287$
DECLARE
    u_emp   uuid := gen_random_uuid();   -- 报销人(有员工档案,不持任何码)
    u_fin   uuid := gen_random_uuid();   -- 财务(全权限):替报销人提单、做决定
    u_view  uuid := gen_random_uuid();   -- 只持 module.finance.view 的读者
    u_other uuid := gen_random_uuid();   -- 另一名员工,不持任何码
    r_all uuid; r_view uuid;
    e_emp uuid; e_other uuid;
    v_base text;
    d1 date := date_trunc('month', CURRENT_DATE - 40)::date + 2;
    v_res jsonb; v text; v_n bigint;
    c1 uuid; c2 uuid; c3 uuid; code1 text; code2 text;
    i11 uuid; i12 uuid; i21 uuid; i31 uuid;
    rc_a uuid; rc_b uuid; rc_c uuid; rc_d uuid; rc_e uuid; rc_old uuid; rc_late uuid;
    p_a text; p_b text; p_c text; p_d text; p_e text; p_late text;
BEGIN
    IF NOT EXISTS (SELECT 1 FROM storage.buckets WHERE id = 'claim-receipts' AND file_size_limit = 10485760) THEN
        RAISE EXCEPTION 'FIXTURE 287 布景失败:重建库里没有 claim-receipts 桶 —— storage 桩或 db/storage/buckets-and-policies.sql 没装进来';
    END IF;
    INSERT INTO auth.users (id) VALUES (u_emp), (u_fin), (u_view), (u_other);
    INSERT INTO roles (code, name_en, name_zh, is_active) VALUES ('fixture-287-all', 'f', 'f', true) RETURNING id INTO r_all;
    INSERT INTO role_permissions (role_id, permission_code) SELECT r_all, code FROM permissions;
    INSERT INTO roles (code, name_en, name_zh, is_active) VALUES ('fixture-287-view', 'f', 'f', true) RETURNING id INTO r_view;
    INSERT INTO role_permissions (role_id, permission_code) VALUES (r_view, 'module.finance.view');
    INSERT INTO user_roles (user_id, role_id) VALUES (u_fin, r_all), (u_view, r_view);
    UPDATE finance_settings SET locked_before = NULL, gst_registered = true, approvals_enabled = false,
           gst_registration_no = COALESCE(gst_registration_no, 'ZZ-F287-GST');
    UPDATE account_settings SET portal_upload_max_bytes = 10485760,
           portal_upload_types = ARRAY['application/pdf', 'image/jpeg', 'image/png'] WHERE id;
    SELECT code INTO v_base FROM currencies WHERE is_base;
    INSERT INTO employees (code, legal_name, employment_type, work_category, hire_date, user_id)
    VALUES ('ZZ-F287-E', 'fixture 287 claimant', 'full_time', 'office', CURRENT_DATE - 400, u_emp) RETURNING id INTO e_emp;
    INSERT INTO employees (code, legal_name, employment_type, work_category, hire_date, user_id)
    VALUES ('ZZ-F287-O', 'fixture 287 other', 'full_time', 'office', CURRENT_DATE - 400, u_other) RETURNING id INTO e_other;

    -- c1:员工本人提的两笔;c2:财务替员工提的一笔;c3:员工提了又撤回的一笔
    PERFORM pg_temp.f287_as(u_emp);
    v_res := submit_expense_claim_items(e_emp, v_base, 'fixture 287 trip', jsonb_build_array(
        jsonb_build_object('spend_date', d1, 'amount', 50, 'description', 'taxi'),
        jsonb_build_object('spend_date', d1, 'amount', 30, 'description', 'lunch')));
    c1 := (v_res ->> 'claim_id')::uuid; code1 := v_res ->> 'code';
    i11 := (SELECT (x ->> 'item_id')::uuid FROM jsonb_array_elements(v_res -> 'items') x WHERE (x ->> 'line_no')::int = 1);
    i12 := (SELECT (x ->> 'item_id')::uuid FROM jsonb_array_elements(v_res -> 'items') x WHERE (x ->> 'line_no')::int = 2);
    IF i11 IS NULL OR i12 IS NULL OR i11 <> (SELECT id FROM expense_claim_items WHERE claim_id = c1 AND line_no = 1) THEN
        RAISE EXCEPTION 'FIXTURE 287 布景失败:submit_expense_claim_items 应当回每一笔的 id(Q12),实得 %', v_res; END IF;
    v_res := submit_expense_claim_items(e_emp, v_base, 'fixture 287 withdrawn', jsonb_build_array(
        jsonb_build_object('spend_date', d1, 'amount', 5, 'description', 'bus')));
    c3 := (v_res ->> 'claim_id')::uuid; i31 := (SELECT id FROM expense_claim_items WHERE claim_id = c3);
    PERFORM withdraw_expense_claim(c3);
    PERFORM pg_temp.f287_as(u_fin);
    v_res := submit_expense_claim_items(e_emp, v_base, 'fixture 287 on behalf', jsonb_build_array(
        jsonb_build_object('spend_date', d1, 'amount', 12, 'description', 'parking')));
    c2 := (v_res ->> 'claim_id')::uuid; code2 := v_res ->> 'code'; i21 := (SELECT id FROM expense_claim_items WHERE claim_id = c2);
    PERFORM pg_temp.f287_as(NULL);

    -- ══════════ A · BEGIN ══════════
    v := pg_temp.f287_call(u_emp, format('SELECT claim_receipt_begin(%L::uuid, ''r.pdf'', ''application/pdf'', 100)::text', gen_random_uuid()));
    IF v <> 'ERR|CLAIM_RECEIPT_ITEM_NOT_FOUND' THEN RAISE EXCEPTION 'FIXTURE 287A 失败:不存在的那一笔 → %', v; END IF;
    v := pg_temp.f287_call(u_other, format('SELECT claim_receipt_begin(%L::uuid, ''r.pdf'', ''application/pdf'', 100)::text', i11));
    IF v <> 'ERR|CLAIM_RECEIPT_NOT_YOURS|' || code1 THEN RAISE EXCEPTION 'FIXTURE 287A 失败:另一名员工 → %', v; END IF;
    v := pg_temp.f287_call(u_view, format('SELECT claim_receipt_begin(%L::uuid, ''r.pdf'', ''application/pdf'', 100)::text', i11));
    IF v <> 'ERR|CLAIM_RECEIPT_NOT_YOURS|' || code1 THEN RAISE EXCEPTION 'FIXTURE 287A 失败:只持 finance.view 的读者传不了(Q4)→ %', v; END IF;
    v := pg_temp.f287_call(u_emp, format('SELECT claim_receipt_begin(%L::uuid, ''r.heic'', ''image/heic'', 100)::text', i11));
    IF v <> 'ERR|CLAIM_RECEIPT_TYPE_NOT_ACCEPTED|image/heic' THEN RAISE EXCEPTION 'FIXTURE 287A 失败:HEIC → %', v; END IF;
    v := pg_temp.f287_call(u_emp, format('SELECT claim_receipt_begin(%L::uuid, ''r.docx'', %L, 100)::text', i11,
                                         'application/vnd.openxmlformats-officedocument.wordprocessingml.document'));
    IF v NOT LIKE 'ERR|CLAIM_RECEIPT_TYPE_NOT_ACCEPTED|application/vnd.openxml%' THEN RAISE EXCEPTION 'FIXTURE 287A 失败:Word → %', v; END IF;
    v := pg_temp.f287_call(u_emp, format('SELECT claim_receipt_begin(%L::uuid, ''r.pdf'', ''application/pdf'', 0)::text', i11));
    IF v <> 'ERR|CLAIM_RECEIPT_EMPTY' THEN RAISE EXCEPTION 'FIXTURE 287A 失败:空文件 → %', v; END IF;
    v := pg_temp.f287_call(u_emp, format('SELECT claim_receipt_begin(%L::uuid, ''r.pdf'', ''application/pdf'', 10485761)::text', i11));
    IF v <> 'ERR|CLAIM_RECEIPT_TOO_LARGE|10485760' THEN RAISE EXCEPTION 'FIXTURE 287A 失败:超过 10 MB → %', v; END IF;
    v := pg_temp.f287_call(u_emp, format('SELECT claim_receipt_begin(%L::uuid, ''  '', ''application/pdf'', 100)::text', i11));
    IF v <> 'ERR|CLAIM_RECEIPT_NAME_REQUIRED' THEN RAISE EXCEPTION 'FIXTURE 287A 失败:空文件名 → %', v; END IF;
    v := pg_temp.f287_call(u_emp, format('SELECT claim_receipt_begin(%L::uuid, ''r.pdf'', ''application/pdf'', 100)::text', i31));
    IF v NOT LIKE 'ERR|CLAIM_RECEIPT_CLAIM_NOT_SUBMITTED|%|withdrawn' THEN RAISE EXCEPTION 'FIXTURE 287A 失败:撤回的单 → %', v; END IF;
    -- 存储到了 900 MB(Q10):一个已有的大对象把总量推到上限之下 100 字节,再来 200 字节就按名拒
    INSERT INTO storage.objects (bucket_id, name, metadata)
    VALUES ('finance-attachments', 'f287/huge.pdf', jsonb_build_object('size', 943718400 - 100 - (SELECT COALESCE(sum((metadata ->> 'size')::bigint), 0) FROM storage.objects)));
    v := pg_temp.f287_call(u_emp, format('SELECT claim_receipt_begin(%L::uuid, ''r.pdf'', ''application/pdf'', 200)::text', i11));
    IF v NOT LIKE 'ERR|CLAIM_RECEIPT_STORAGE_FULL|%|943718400' THEN RAISE EXCEPTION 'FIXTURE 287A 失败:存储满 → %', v; END IF;
    v := pg_temp.f287_call(u_emp, format('SELECT claim_receipt_begin(%L::uuid, ''r.pdf'', ''application/pdf'', 100)::text', i11));
    IF v LIKE 'ERR|%' THEN RAISE EXCEPTION 'FIXTURE 287A 失败:上限之下 100 字节应当还收得下 → %', v; END IF;
    UPDATE expense_claim_receipts SET status = 'abandoned' WHERE id = (v::jsonb ->> 'id')::uuid;
    DELETE FROM storage.objects WHERE bucket_id = 'finance-attachments' AND name = 'f287/huge.pdf';
    IF EXISTS (SELECT 1 FROM expense_claim_receipts WHERE status <> 'abandoned') THEN
        RAISE EXCEPTION 'FIXTURE 287A 失败:被拒的 begin 不该登记任何一行'; END IF;
    -- 过了:员工本人(c1 第 1 笔两份、第 2 笔一份)与替他提单的财务(c2)
    v_res := pg_temp.f287_call(u_emp, format('SELECT claim_receipt_begin(%L::uuid, ''taxi.pdf'', ''application/pdf'', 1000)::text', i11))::jsonb;
    rc_a := (v_res ->> 'id')::uuid; p_a := v_res ->> 'path';
    IF v_res ->> 'bucket' <> 'claim-receipts' OR p_a <> c1::text || '/' || i11::text || '/' || rc_a::text || '.pdf' THEN
        RAISE EXCEPTION 'FIXTURE 287A 失败:路径应当是 <单>/<笔>/<收据>.pdf,实得 %', v_res; END IF;
    v_res := pg_temp.f287_call(u_emp, format('SELECT claim_receipt_begin(%L::uuid, ''taxi-page2.jpg'', ''image/jpeg'', 500)::text', i11))::jsonb;
    rc_b := (v_res ->> 'id')::uuid; p_b := v_res ->> 'path';
    v_res := pg_temp.f287_call(u_emp, format('SELECT claim_receipt_begin(%L::uuid, ''lunch.png'', ''image/png'', 700)::text', i12))::jsonb;
    rc_c := (v_res ->> 'id')::uuid; p_c := v_res ->> 'path';
    v_res := pg_temp.f287_call(u_fin, format('SELECT claim_receipt_begin(%L::uuid, ''parking.pdf'', ''application/pdf'', 300)::text', i21))::jsonb;
    rc_d := (v_res ->> 'id')::uuid; p_d := v_res ->> 'path';
    IF rc_a IS NULL OR rc_b IS NULL OR rc_c IS NULL OR rc_d IS NULL
       OR (SELECT count(*) FROM expense_claim_receipts WHERE status = 'uploading') <> 4
       OR (SELECT created_by FROM expense_claim_receipts WHERE id = rc_d) <> u_fin THEN
        RAISE EXCEPTION 'FIXTURE 287A 失败:员工本人与替他提单的人都应当登记得了(Q4)'; END IF;

    -- ══════════ B · UPLOAD(存储策略)══════════
    IF pg_temp.f287_rc(u_emp, format('INSERT INTO storage.objects (bucket_id, name, metadata) VALUES (''claim-receipts'', %L, %L)',
                                     p_a, jsonb_build_object('size', 1000, 'mimetype', 'application/pdf'))) <> 1 THEN
        RAISE EXCEPTION 'FIXTURE 287B 失败:登记的人传不进登记的路径'; END IF;
    IF pg_temp.f287_rc(u_emp, format('INSERT INTO storage.objects (bucket_id, name) VALUES (''claim-receipts'', %L)', c1::text || '/elsewhere.pdf')) <> -1 THEN
        RAISE EXCEPTION 'FIXTURE 287B 失败:一条没登记过的路径传得进'; END IF;
    IF pg_temp.f287_rc(u_other, format('INSERT INTO storage.objects (bucket_id, name) VALUES (''claim-receipts'', %L)', p_b)) <> -1
       OR pg_temp.f287_rc(u_fin, format('INSERT INTO storage.objects (bucket_id, name) VALUES (''claim-receipts'', %L)', p_b)) <> -1 THEN
        RAISE EXCEPTION 'FIXTURE 287B 失败:别人传得进员工登记的路径(连财务也不行 —— 判的是登记的人)'; END IF;
    INSERT INTO expense_claim_receipts (claim_id, item_id, file_name, file_type, file_size, storage_path, created_by, created_at)
    VALUES (c1, i12, 'old.pdf', 'application/pdf', 10, c1::text || '/' || i12::text || '/old.pdf', u_emp, now() - interval '11 minutes')
    RETURNING id INTO rc_old;
    IF pg_temp.f287_rc(u_emp, format('INSERT INTO storage.objects (bucket_id, name) VALUES (''claim-receipts'', %L)', c1::text || '/' || i12::text || '/old.pdf')) <> -1 THEN
        RAISE EXCEPTION 'FIXTURE 287B 失败:十分钟以前登记的路径还传得进'; END IF;
    PERFORM pg_temp.f287_rc(u_emp, format('INSERT INTO storage.objects (bucket_id, name, metadata) VALUES (''claim-receipts'', %L, %L)',
                                          p_b, jsonb_build_object('size', 500, 'mimetype', 'image/jpeg')));
    PERFORM pg_temp.f287_rc(u_emp, format('INSERT INTO storage.objects (bucket_id, name, metadata) VALUES (''claim-receipts'', %L, %L)',
                                          p_c, jsonb_build_object('size', 999, 'mimetype', 'image/png')));   -- 大小对不上(C 臂)
    -- 这张单的【另一个】人(员工本人)也传不进替他提单的财务登记的那一条路径 —— 判的是登记的那个会话,不只是"这张单的人"
    IF pg_temp.f287_rc(u_emp, format('INSERT INTO storage.objects (bucket_id, name) VALUES (''claim-receipts'', %L)', p_d)) <> -1 THEN
        RAISE EXCEPTION 'FIXTURE 287B 失败:员工本人传得进替他提单的人登记的路径'; END IF;
    IF pg_temp.f287_rc(u_fin, format('INSERT INTO storage.objects (bucket_id, name, metadata) VALUES (''claim-receipts'', %L, %L)',
                                     p_d, jsonb_build_object('size', 300, 'mimetype', 'application/pdf'))) <> 1 THEN
        RAISE EXCEPTION 'FIXTURE 287B 失败:替人提单的财务传不进自己登记的路径'; END IF;
    -- 没有人改得动、删得掉(Q5)
    FOREACH v IN ARRAY ARRAY[u_emp::text, u_fin::text, u_view::text] LOOP
        IF pg_temp.f287_rc(v::uuid, 'DELETE FROM storage.objects WHERE bucket_id = ''claim-receipts''') > 0
           OR pg_temp.f287_rc(v::uuid, 'UPDATE storage.objects SET metadata = ''{}''::jsonb WHERE bucket_id = ''claim-receipts''') > 0 THEN
            RAISE EXCEPTION 'FIXTURE 287B 失败:有人改得动或删得掉 claim-receipts 里的对象'; END IF;
    END LOOP;

    -- ══════════ C · FINISH ══════════
    v := pg_temp.f287_call(u_other, format('SELECT claim_receipt_finish(%L::uuid)::text', rc_a));
    IF v <> 'ERR|CLAIM_RECEIPT_NOT_FOUND' THEN RAISE EXCEPTION 'FIXTURE 287C 失败:别人 finish → %', v; END IF;
    v := pg_temp.f287_call(u_emp, format('SELECT claim_receipt_finish(%L::uuid)::text', rc_c));
    IF v <> 'ERR|CLAIM_RECEIPT_MISMATCH' THEN RAISE EXCEPTION 'FIXTURE 287C 失败:大小对不上 → %', v; END IF;
    PERFORM pg_temp.f287_call(u_emp, format('SELECT claim_receipt_abandon(%L::uuid)::text', rc_c));
    v_res := pg_temp.f287_call(u_emp, format('SELECT claim_receipt_begin(%L::uuid, ''lunch-again.pdf'', ''application/pdf'', 400)::text', i12))::jsonb;
    rc_e := (v_res ->> 'id')::uuid; p_e := v_res ->> 'path';
    v := pg_temp.f287_call(u_emp, format('SELECT claim_receipt_finish(%L::uuid)::text', rc_e));
    IF v <> 'ERR|CLAIM_RECEIPT_NOT_STORED' THEN RAISE EXCEPTION 'FIXTURE 287C 失败:对象不在 → %', v; END IF;
    FOREACH v IN ARRAY ARRAY[rc_a::text, rc_b::text] LOOP
        IF pg_temp.f287_call(u_emp, format('SELECT claim_receipt_finish(%L::uuid)::text', v)) LIKE 'ERR|%' THEN
            RAISE EXCEPTION 'FIXTURE 287C 失败:对得上的那份 finish 不了'; END IF;
    END LOOP;
    IF pg_temp.f287_call(u_fin, format('SELECT claim_receipt_finish(%L::uuid)::text', rc_d)) LIKE 'ERR|%' THEN
        RAISE EXCEPTION 'FIXTURE 287C 失败:替人提单的财务 finish 不了自己那份'; END IF;
    v := pg_temp.f287_call(u_emp, format('SELECT claim_receipt_finish(%L::uuid)::text', rc_a));
    IF v <> 'ERR|CLAIM_RECEIPT_NOT_UPLOADING|attached' THEN RAISE EXCEPTION 'FIXTURE 287C 失败:再 finish 一次 → %', v; END IF;
    IF (SELECT status FROM expense_claim_receipts WHERE id = rc_c) <> 'abandoned'
       OR (SELECT count(*) FROM expense_claim_receipts WHERE item_id = i11 AND status = 'attached' AND attached_at IS NOT NULL) <> 2 THEN
        RAISE EXCEPTION 'FIXTURE 287C 失败:第 1 笔应当两份 attached(Q9),没传成的那份 abandoned'; END IF;

    -- ══════════ D · READ ══════════
    IF pg_temp.f287_rc(u_view, 'SELECT count(*) FROM expense_claim_receipts') <> (SELECT count(*) FROM expense_claim_receipts)
       OR pg_temp.f287_rc(u_view, 'SELECT count(*) FROM storage.objects WHERE bucket_id = ''claim-receipts''')
          <> (SELECT count(*) FROM storage.objects WHERE bucket_id = 'claim-receipts') THEN
        RAISE EXCEPTION 'FIXTURE 287D 失败:finance.view 应当读得到全部的行与对象(Q7)'; END IF;
    IF pg_temp.f287_rc(u_other, 'SELECT count(*) FROM expense_claim_receipts') <> 0
       OR pg_temp.f287_rc(u_other, 'SELECT count(*) FROM storage.objects WHERE bucket_id = ''claim-receipts''') <> 0 THEN
        RAISE EXCEPTION 'FIXTURE 287D 失败:另一名员工读到了别人的收据'; END IF;
    IF pg_temp.f287_rc(u_emp, format('SELECT count(*) FROM storage.objects WHERE bucket_id = ''claim-receipts'' AND name IN (%L, %L, %L)', p_a, p_b, p_d)) <> 3
       OR pg_temp.f287_rc(u_emp, format('SELECT count(*) FROM expense_claim_receipts WHERE claim_id IN (%L, %L)', c1, c2))
          <> (SELECT count(*) FROM expense_claim_receipts WHERE claim_id IN (c1, c2)) THEN
        RAISE EXCEPTION 'FIXTURE 287D 失败:员工应当读得到自己两张单的收据(含财务替他提的那张,Q6)'; END IF;
    IF pg_temp.f287_rc(u_emp, format('SELECT count(*) FROM storage.objects WHERE bucket_id = ''claim-receipts'' AND name = %L', p_c)) <> 0 THEN
        RAISE EXCEPTION 'FIXTURE 287D 失败:一份没传成(abandoned)的对象员工还读得到'; END IF;

    -- ══════════ E · REMOVE ══════════
    v := pg_temp.f287_call(u_other, format('SELECT claim_receipt_remove(%L::uuid)::text', rc_b));
    IF v <> 'ERR|CLAIM_RECEIPT_NOT_YOURS|' || code1 THEN RAISE EXCEPTION 'FIXTURE 287E 失败:别人拿掉 → %', v; END IF;
    v := pg_temp.f287_call(u_emp, format('SELECT claim_receipt_remove(%L::uuid)::text', rc_b));
    IF v LIKE 'ERR|%' OR NOT EXISTS (SELECT 1 FROM expense_claim_receipts WHERE id = rc_b AND status = 'removed'
                                         AND removed_by = u_emp AND removed_at IS NOT NULL) THEN
        RAISE EXCEPTION 'FIXTURE 287E 失败:员工在 submitted 时拿掉一份 → %', v; END IF;
    IF NOT EXISTS (SELECT 1 FROM storage.objects WHERE bucket_id = 'claim-receipts' AND name = p_b) THEN
        RAISE EXCEPTION 'FIXTURE 287E 失败:拿掉之后对象应当留在桶里(Q5)'; END IF;
    IF pg_temp.f287_rc(u_emp, format('SELECT count(*) FROM storage.objects WHERE bucket_id = ''claim-receipts'' AND name = %L', p_b)) <> 0
       OR pg_temp.f287_rc(u_view, format('SELECT count(*) FROM storage.objects WHERE bucket_id = ''claim-receipts'' AND name = %L', p_b)) <> 1 THEN
        RAISE EXCEPTION 'FIXTURE 287E 失败:拿掉的那份员工不该再读到、财务应当照样读到'; END IF;
    v := pg_temp.f287_call(u_emp, format('SELECT claim_receipt_remove(%L::uuid)::text', rc_b));
    IF v <> 'ERR|CLAIM_RECEIPT_NOT_ATTACHED|removed' THEN RAISE EXCEPTION 'FIXTURE 287E 失败:拿掉两次 → %', v; END IF;

    -- ══════════ F · DECIDE(逐笔)══════════
    -- 第 2 笔此刻:一份 abandoned、一份 uploading(过期)、一份 uploading(对象不在)—— 没有一份算凭据,也没有理由
    v := pg_temp.f287_call(u_fin, format($q$SELECT decide_expense_claim_items(%L::uuid, true, '[{"line_no":1,"account_code":"6120","tax_code":"TX"},{"line_no":2,"account_code":"6120","tax_code":"TX"}]'::jsonb, NULL, NULL)::text$q$, c1));
    IF v <> 'ERR|EXPENSE_CLAIM_NO_EVIDENCE|' || code1 || '|2' THEN RAISE EXCEPTION 'FIXTURE 287F 失败:第 2 笔没有 attached 的收据 → %', v; END IF;
    -- 第 1 笔被拿掉一份之后仍有一份 attached —— 不是它拦的;给第 2 笔补一份 attached
    PERFORM pg_temp.f287_rc(u_emp, format('INSERT INTO storage.objects (bucket_id, name, metadata) VALUES (''claim-receipts'', %L, %L)',
                                          p_e, jsonb_build_object('size', 400, 'mimetype', 'application/pdf')));
    IF pg_temp.f287_call(u_emp, format('SELECT claim_receipt_finish(%L::uuid)::text', rc_e)) LIKE 'ERR|%' THEN
        RAISE EXCEPTION 'FIXTURE 287F 失败:第 2 笔的收据 finish 不了'; END IF;
    -- 一份在途的(begin 了、还没传完)留到批准之后,G 臂用
    v_res := pg_temp.f287_call(u_emp, format('SELECT claim_receipt_begin(%L::uuid, ''late.pdf'', ''application/pdf'', 50)::text', i12))::jsonb;
    rc_late := (v_res ->> 'id')::uuid; p_late := v_res ->> 'path';
    v := pg_temp.f287_call(u_fin, format($q$SELECT decide_expense_claim_items(%L::uuid, true, '[{"line_no":1,"account_code":"6120","tax_code":"TX"},{"line_no":2,"account_code":"6120","tax_code":"TX"}]'::jsonb, NULL, NULL)::text$q$, c1));
    IF v LIKE 'ERR|%' OR (SELECT status FROM expense_claims WHERE id = c1) <> 'approved' THEN
        RAISE EXCEPTION 'FIXTURE 287F 失败:每一笔都有 attached 的收据应当批得过 → %', v; END IF;

    -- ══════════ G · AFTER ══════════
    v := pg_temp.f287_call(u_emp, format('SELECT claim_receipt_begin(%L::uuid, ''r.pdf'', ''application/pdf'', 100)::text', i11));
    IF v <> 'ERR|CLAIM_RECEIPT_CLAIM_NOT_SUBMITTED|' || code1 || '|approved' THEN RAISE EXCEPTION 'FIXTURE 287G 失败:批准之后 begin → %', v; END IF;
    IF pg_temp.f287_rc(u_emp, format('INSERT INTO storage.objects (bucket_id, name) VALUES (''claim-receipts'', %L)', p_late)) <> -1 THEN
        RAISE EXCEPTION 'FIXTURE 287G 失败:单被批了之后,在途那一条路径还传得进'; END IF;
    INSERT INTO storage.objects (bucket_id, name, metadata) VALUES ('claim-receipts', p_late, jsonb_build_object('size', 50, 'mimetype', 'application/pdf'));
    v := pg_temp.f287_call(u_emp, format('SELECT claim_receipt_finish(%L::uuid)::text', rc_late));
    IF v <> 'ERR|CLAIM_RECEIPT_CLAIM_NOT_SUBMITTED|' || code1 || '|approved' THEN RAISE EXCEPTION 'FIXTURE 287G 失败:上传途中被批 → %', v; END IF;
    v := pg_temp.f287_call(u_emp, format('SELECT claim_receipt_remove(%L::uuid)::text', rc_a));
    IF v <> 'ERR|CLAIM_RECEIPT_CLAIM_NOT_SUBMITTED|' || code1 || '|approved' THEN RAISE EXCEPTION 'FIXTURE 287G 失败:批准之后拿掉 → %', v; END IF;
    IF pg_temp.f287_rc(u_emp, format('SELECT count(*) FROM storage.objects WHERE bucket_id = ''claim-receipts'' AND name = %L', p_a)) <> 1 THEN
        RAISE EXCEPTION 'FIXTURE 287G 失败:批准之后员工应当照样读得到自己的收据(Q6)'; END IF;

    -- ══════════ H · GUARD ══════════
    BEGIN UPDATE expense_claim_receipts SET status = 'uploading', attached_at = NULL WHERE id = rc_a; v := 'OK';
    EXCEPTION WHEN OTHERS THEN v := SQLERRM; END;
    IF v <> 'CLAIM_RECEIPT_IMMUTABLE' THEN RAISE EXCEPTION 'FIXTURE 287H 失败:attached → uploading → %', v; END IF;
    BEGIN UPDATE expense_claim_receipts SET storage_path = 'x' WHERE id = rc_d; v := 'OK';
    EXCEPTION WHEN OTHERS THEN v := SQLERRM; END;
    IF v <> 'CLAIM_RECEIPT_IMMUTABLE' THEN RAISE EXCEPTION 'FIXTURE 287H 失败:改路径 → %', v; END IF;
    BEGIN DELETE FROM expense_claim_receipts WHERE id = rc_d; v := 'OK';
    EXCEPTION WHEN OTHERS THEN v := SQLERRM; END;
    IF v <> 'CLAIM_RECEIPT_IMMUTABLE' THEN RAISE EXCEPTION 'FIXTURE 287H 失败:删行 → %', v; END IF;
    IF pg_temp.f287_rc(u_fin, format('UPDATE expense_claim_receipts SET file_name = ''y'' WHERE id = %L', rc_d)) <> -1 THEN
        RAISE EXCEPTION 'FIXTURE 287H 失败:authenticated 有写这张表的路'; END IF;

    -- ══════════ I · SHAPE ══════════
    IF EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema = 'public' AND table_name = 'finance_attachments' AND column_name = 'claim_id')
       OR EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema = 'public' AND table_name = 'expense_claim_status' AND column_name = 'has_receipt') THEN
        RAISE EXCEPTION 'FIXTURE 287I 失败:整张单的附件那条路还在(Q13)'; END IF;
    IF (SELECT count(*) FROM trail_subject_members() m WHERE m.subject IN ('expense_claim', 'my_expense_claim') AND m.table_name = 'expense_claim_receipts') <> 2
       OR EXISTS (SELECT 1 FROM trail_subject_members() m WHERE m.subject IN ('expense_claim', 'my_expense_claim') AND m.table_name = 'finance_attachments') THEN
        RAISE EXCEPTION 'FIXTURE 287I 失败:两条报销单审计记录应当挂收据、不再挂 finance_attachments'; END IF;

    RAISE NOTICE 'FIXTURE 287 全部通过: BEGIN · UPLOAD · FINISH · READ · REMOVE · DECIDE · AFTER · GUARD · SHAPE';
END
$f287$;
ROLLBACK;

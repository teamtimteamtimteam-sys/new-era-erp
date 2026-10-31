-- ═══════════════════════════════════════════════════════════════════════════
-- fixture 277 —— 一个供应商门户账号只能为它自己那一家交一份证书(V39:10 MB · PDF / JPEG / PNG,超了或类型不对在任何字节存下之前按名拒);
--   一份交上来的证书只是一份等审核的申请 —— 什么别的都不改;员工 module.suppliers.edit 接受(建 supplier_compliance 行、文件抄进
--   supplier-attachments 那一行挂上)或驳回(理由必填,供应商看得见)(MES-9c,2026-10-20;MES-9 Step 0 §5 · Q19 · Q25 · V39,Tim)
-- ═══════════════════════════════════════════════════════════════════════════
-- 臂:
--   V39      portal_submission_begin:超过上限 → PORTAL_UPLOAD_TOO_LARGE|10485760;GIF → PORTAL_UPLOAD_TYPE_NOT_ACCEPTED;空 → PORTAL_UPLOAD_EMPTY;
--            V39 清空 → PORTAL_UPLOAD_LIMITS_NOT_SET;每一次拒绝之后申请表与 storage.objects 一行都没多;没有一行 uploading 的申请时,
--            门户会话往 portal-uploads 的任何路径都传不进去(42501)—— 所以没过 V39 的字节存不下
--   ONLY     一份上传(begin → 门户自己传字节 → finish)只多了申请表的那一行与桶里那一份:别的每一张 public 表的指纹逐字不变
--            (库存、价钱、总账、证书、附件都在内);变更记录只多了申请表自己的行,作者是门户账号
--   UPLOAD   传字节的那条策略:只放行自己那一行 uploading 申请登记的那一条路径;别的路径、别家的、交完的、十分钟以前登记的 → 42501;
--            finish:没有字节 → PORTAL_UPLOAD_NOT_STORED,大小 / 类型对不上 → PORTAL_UPLOAD_MISMATCH,交过的 → NOT_UPLOADING;abandon 收回
--   ACCEPT   module.suppliers.edit 接受:文件没抄过去 → PORTAL_SUBMISSION_FILE_NOT_COPIED;抄到别家目录 → FILE_PATH_INVALID;抄过去了 →
--            一行 supplier_compliance(类型取申请的、号与有效期取员工核过的)与一行 supplier_attachments(那条路径),申请 → accepted 并挂上两者;
--            再接受一次 → NOT_WAITING;门户上看得见 accepted,在册证书里多了这一张
--   REJECT   没有理由 → PORTAL_SUBMISSION_REASON_REQUIRED;有理由 → rejected,门户上看得见理由;没有证书行、没有附件行
--   REVIEW   只有 module.suppliers.edit 审得动:只持 module.suppliers.view 的 → PERMISSION_DENIED;没有码的同;门户会话调不到(42501);
--            读:module.suppliers.view 读得到申请,没有码的读 0 行,门户会话直接读表 → 42501
--   EVERY    supplier_portal 能执行的【每一支】public 函数(从目录里枚举):MES-9c 的五支在这里各有两家供应商的用例,MES-9a 的两支在 275、
--            MES-9b 的四支在 276;三支 fixture 合起来必须正好覆盖目录。每一支:A 只见 A、B 只见 B;员工会话 42501;令牌声明不对 / 会话结束 /
--            没有会话 / 不是门户账号 / 被封 → 各自按名拒(portal_can_upload_object 是 RLS 判据,绝不抛 —— 一律回 false)
--   GRANTS   五支只授 supplier_portal;两支员工函数门户调不到;storage.objects 的 INSERT 授给门户;作用于门户的存储策略恰好三条(两条按名是本刀的)
--   TRAIL    门户账号写的那几行,trail_actor 说 portal + 供应商名(「Supplier portal — <供应商名>」由 check-trail-wording ㊲ 钉住);
--            申请表在供应商的审计记录主语下(trail_subject_members,家在 supplier)
--   EXCL     变更记录的豁免仍是 9、零缺口;申请表被记录;遮蔽名单里没有它的列;V39 的待补那一支:设着时 0 行、清空时 1 行
-- 前提:db/platform-prelude.sql 建了 supplier_portal 与 auth.sessions;db/gate.py 在 fixture 之前装好了 storage 桩与 db/storage/buckets-and-policies.sql。
--   自带数据(README 第 2 条)。注入(故障注入的记录在 docs/handbacks/MES-9c.md):db/scripts/2026-10-20-mes9c-fixture-injections.py。
-- ═══════════════════════════════════════════════════════════════════════════

BEGIN;
SET LOCAL statement_timeout = '300s';

CREATE FUNCTION pg_temp.f277_claims(p_user uuid, p_role text, p_sid uuid) RETURNS void
LANGUAGE sql AS $f$
    SELECT set_config('request.jwt.claims',
                      CASE WHEN p_user IS NULL THEN ''
                           ELSE jsonb_build_object('sub', p_user, 'role', p_role, 'session_id', p_sid)::text END, true)
$f$;

-- 以 (账号, 数据库角色, 令牌里的 role 声明, 会话) 跑一句,回结果的文字;出错回 'ERR|<sqlstate>|<消息>'
CREATE FUNCTION pg_temp.f277_call(p_user uuid, p_dbrole text, p_claim text, p_sid uuid, p_sql text) RETURNS text
LANGUAGE plpgsql AS $f$
DECLARE v text;
BEGIN
    PERFORM pg_temp.f277_claims(p_user, p_claim, p_sid);
    EXECUTE format('SET LOCAL ROLE %I', p_dbrole);
    EXECUTE p_sql INTO v;
    EXECUTE 'RESET ROLE';
    PERFORM pg_temp.f277_claims(NULL, NULL, NULL);
    RETURN COALESCE(v, '<null>');
EXCEPTION WHEN OTHERS THEN
    EXECUTE 'RESET ROLE';
    PERFORM pg_temp.f277_claims(NULL, NULL, NULL);
    RETURN 'ERR|' || SQLSTATE || '|' || SQLERRM;
END;
$f$;

CREATE FUNCTION pg_temp.f277_who(p_codes text[]) RETURNS uuid
LANGUAGE plpgsql AS $f$
DECLARE r uuid; u uuid := gen_random_uuid();
BEGIN
    INSERT INTO auth.users (id, email, email_confirmed_at) VALUES (u, 'fx277-' || left(u::text, 8) || '@test.local', now());
    INSERT INTO roles (code, name_en, name_zh, is_active) VALUES ('fx277-' || left(u::text, 8), 'f', 'f', true) RETURNING id INTO r;
    INSERT INTO role_permissions (role_id, permission_code) SELECT DISTINCT r, c FROM unnest(p_codes) c;
    INSERT INTO user_roles (user_id, role_id) VALUES (u, r);
    RETURN u;
END;
$f$;

-- 每一张 public 基表(申请表与变更记录除外)的指纹 —— ONLY 臂比"之前 / 之后"
CREATE FUNCTION pg_temp.f277_prints() RETURNS TABLE(t text, h text)
LANGUAGE plpgsql AS $f$
DECLARE r record; v text;
BEGIN
    FOR r IN SELECT c.relname FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
              WHERE n.nspname = 'public' AND c.relkind IN ('r', 'p')
                AND c.relname NOT IN ('portal_certificate_submissions', 'change_log') ORDER BY 1 LOOP
        EXECUTE format('SELECT md5(COALESCE(string_agg(x::text, ''|'' ORDER BY x::text), '''')) FROM public.%I x', r.relname) INTO v;
        t := r.relname; h := v; RETURN NEXT;
    END LOOP;
END;
$f$;

DO $f277$
DECLARE
    s_a uuid; s_b uuid; c_a uuid; c_b uuid;
    u_a uuid := gen_random_uuid(); u_b uuid := gen_random_uuid(); u_x uuid := gen_random_uuid();
    sid_a uuid := gen_random_uuid(); sid_b uuid := gen_random_uuid(); sid_x uuid := gen_random_uuid();
    l_a uuid; l_b uuid; u_edit uuid; u_view uuid; u_none uuid; u_perm uuid;
    v text; v_j jsonb; v_n bigint; v_n0 bigint; v_o0 bigint; v_cl0 bigint; v_k bigint; v_m bigint;
    sub1 uuid; path1 text; sub2 uuid; path2 text; sub3 uuid; sub4 uuid; path4 text; sub5 uuid; path5 text; sub_b uuid; path_b text;
    sub6 uuid; path6 text; sub7 uuid; path7 text;
    v_att_path text; r record; v_fn text; v_other text; v_bad text; v_cases jsonb;
    v_before text[] := ARRAY['portal_me()', 'portal_export_my_data()', 'portal_documents()', 'portal_deliveries()',
                             'portal_document_open(p_kind text, p_issue_id uuid)', 'portal_can_read_object(p_bucket text, p_name text)'];
    v_begin text := 'SELECT public.portal_submission_begin(p_cert_type => %L, p_cert_no => %L, p_valid_from => %L::date, p_valid_until => %L::date, p_file_name => %L, p_file_type => %L, p_file_size => %s)::text';
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'supplier_portal') OR to_regclass('auth.sessions') IS NULL
       OR to_regclass('storage.objects') IS NULL OR NOT EXISTS (SELECT 1 FROM storage.buckets WHERE id = 'portal-uploads') THEN
        RAISE EXCEPTION 'FIXTURE 277 SETUP: the prelude / storage stub / storage mirror did not create supplier_portal / auth.sessions / storage.objects / portal-uploads on this rebuild';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM certificate_types WHERE code = 'nea_import' AND is_active) THEN
        RAISE EXCEPTION 'FIXTURE 277 SETUP: the certificate_types bootstrap has no active nea_import';
    END IF;
    IF (SELECT portal_upload_max_bytes FROM account_settings WHERE id) IS DISTINCT FROM 10485760
       OR (SELECT portal_upload_types FROM account_settings WHERE id) IS DISTINCT FROM ARRAY['application/pdf', 'image/jpeg', 'image/png'] THEN
        RAISE EXCEPTION 'FIXTURE 277 SETUP: V39 is not Tim''s 10 MB · PDF / JPEG / PNG on the bootstrap row';
    END IF;

    -- ── data of its own ─────────────────────────────────────────────────────
    INSERT INTO suppliers (code, legal_name, country, status, counterparty_type) VALUES ('FX277-SA', 'fixture 277 supplier A', 'SG', 'active', 'goods_supplier') RETURNING id INTO s_a;
    INSERT INTO suppliers (code, legal_name, country, status, counterparty_type) VALUES ('FX277-SB', 'fixture 277 supplier B', 'SG', 'active', 'goods_supplier') RETURNING id INTO s_b;
    INSERT INTO counterparty_contacts (supplier_id, name, email) VALUES (s_a, 'Ada FX277', 'ada.fx277@a.test') RETURNING id INTO c_a;
    INSERT INTO counterparty_contacts (supplier_id, name, email) VALUES (s_b, 'Bea FX277', 'bea.fx277@b.test') RETURNING id INTO c_b;
    INSERT INTO auth.users (id, email, email_confirmed_at) VALUES (u_a, 'ada.fx277@a.test', now()), (u_b, 'bea.fx277@b.test', now()),
                                                                  (u_x, 'x.fx277@test.local', now());
    INSERT INTO auth.sessions (id, user_id) VALUES (sid_a, u_a), (sid_b, u_b), (sid_x, u_x);
    INSERT INTO supplier_portal_users (user_id, supplier_id, contact_id) VALUES (u_a, s_a, c_a) RETURNING id INTO l_a;
    INSERT INTO supplier_portal_users (user_id, supplier_id, contact_id) VALUES (u_b, s_b, c_b) RETURNING id INTO l_b;
    u_edit := pg_temp.f277_who(ARRAY['module.suppliers.view', 'module.suppliers.edit']);
    u_view := pg_temp.f277_who(ARRAY['module.suppliers.view']);
    u_none := pg_temp.f277_who(ARRAY['module.finance.view', 'module.purchasing.view']);
    u_perm := pg_temp.f277_who(ARRAY['action.manage_permissions']);
    SELECT COALESCE(max(seq), 0) INTO v_cl0 FROM change_log;

    -- ── V39 ────────────────────────────────────────────────────────────────
    SELECT count(*) INTO v_n0 FROM portal_certificate_submissions;
    SELECT count(*) INTO v_o0 FROM storage.objects;
    v := pg_temp.f277_call(u_a, 'supplier_portal', 'supplier_portal', sid_a, format(v_begin, 'nea_import', 'N1', NULL, NULL, 'big.pdf', 'application/pdf', 10485761));
    IF v NOT LIKE 'ERR|%PORTAL_UPLOAD_TOO_LARGE|10485760%' THEN RAISE EXCEPTION 'FIXTURE 277 V39: 10 MB + 1 byte → %', v; END IF;
    v := pg_temp.f277_call(u_a, 'supplier_portal', 'supplier_portal', sid_a, format(v_begin, 'nea_import', 'N1', NULL, NULL, 'pic.gif', 'image/gif', 1000));
    IF v NOT LIKE 'ERR|%PORTAL_UPLOAD_TYPE_NOT_ACCEPTED|image/gif%' THEN RAISE EXCEPTION 'FIXTURE 277 V39: a GIF → %', v; END IF;
    v := pg_temp.f277_call(u_a, 'supplier_portal', 'supplier_portal', sid_a, format(v_begin, 'nea_import', 'N1', NULL, NULL, 'empty.pdf', 'application/pdf', 0));
    IF v NOT LIKE 'ERR|%PORTAL_UPLOAD_EMPTY%' THEN RAISE EXCEPTION 'FIXTURE 277 V39: an empty file → %', v; END IF;
    v := pg_temp.f277_call(u_a, 'supplier_portal', 'supplier_portal', sid_a, format(v_begin, 'no_such_type', 'N1', NULL, NULL, 'a.pdf', 'application/pdf', 1000));
    IF v NOT LIKE 'ERR|%PORTAL_CERT_TYPE_UNKNOWN|no_such_type%' THEN RAISE EXCEPTION 'FIXTURE 277 V39: an unknown certificate type → %', v; END IF;
    v := pg_temp.f277_call(u_a, 'supplier_portal', 'supplier_portal', sid_a, format(v_begin, 'nea_import', 'N1', '2027-01-01', '2026-01-01', 'a.pdf', 'application/pdf', 1000));
    IF v NOT LIKE 'ERR|%PORTAL_CERT_DATES_INVALID%' THEN RAISE EXCEPTION 'FIXTURE 277 V39: valid until before valid from → %', v; END IF;
    UPDATE account_settings SET portal_upload_max_bytes = NULL WHERE id;
    v := pg_temp.f277_call(u_a, 'supplier_portal', 'supplier_portal', sid_a, format(v_begin, 'nea_import', 'N1', NULL, NULL, 'a.pdf', 'application/pdf', 1000));
    IF v NOT LIKE 'ERR|%PORTAL_UPLOAD_LIMITS_NOT_SET%' THEN RAISE EXCEPTION 'FIXTURE 277 V39: V39 cleared → %', v; END IF;
    -- the V39 pending arm: one row while it is cleared
    v := pg_temp.f277_call(u_perm, 'authenticated', 'authenticated', NULL, 'SELECT count(*)::text FROM public.pending_values WHERE value_code = ''V39''');
    IF v <> '1' THEN RAISE EXCEPTION 'FIXTURE 277 EXCL: V39 cleared — pending_values lists % row(s) (expected 1)', v; END IF;
    UPDATE account_settings SET portal_upload_max_bytes = 10485760 WHERE id;
    v := pg_temp.f277_call(u_perm, 'authenticated', 'authenticated', NULL, 'SELECT count(*)::text FROM public.pending_values WHERE value_code = ''V39''');
    IF v <> '0' THEN RAISE EXCEPTION 'FIXTURE 277 EXCL: V39 set — pending_values lists % row(s) (expected 0)', v; END IF;
    IF (SELECT count(*) FROM portal_certificate_submissions) <> v_n0 OR (SELECT count(*) FROM storage.objects) <> v_o0 THEN
        RAISE EXCEPTION 'FIXTURE 277 V39: a refused upload left a submission row or a stored object'; END IF;
    -- without a submission there is no path to store bytes at
    v := pg_temp.f277_call(u_a, 'supplier_portal', 'supplier_portal', sid_a,
        format('INSERT INTO storage.objects (bucket_id, name) VALUES (''portal-uploads'', %L) RETURNING name', s_a || '/' || gen_random_uuid() || '.pdf'));
    IF v NOT LIKE 'ERR|42501|%' THEN RAISE EXCEPTION 'FIXTURE 277 V39: bytes stored without a submission → %', v; END IF;

    -- ── ONLY + UPLOAD (A sends one certificate) ─────────────────────────────
    CREATE TEMP TABLE f277_before ON COMMIT DROP AS SELECT * FROM pg_temp.f277_prints();
    v := pg_temp.f277_call(u_a, 'supplier_portal', 'supplier_portal', sid_a, format(v_begin, 'nea_import', 'NEA-277', '2026-01-01', '2027-01-01', 'permit.pdf', 'application/pdf', 12345));
    IF v LIKE 'ERR|%' THEN RAISE EXCEPTION 'FIXTURE 277 UPLOAD: begin → %', v; END IF;
    sub1 := (v::jsonb ->> 'id')::uuid; path1 := v::jsonb ->> 'path';
    IF v::jsonb ->> 'bucket' <> 'portal-uploads' OR path1 <> s_a || '/' || sub1 || '.pdf' THEN RAISE EXCEPTION 'FIXTURE 277 UPLOAD: begin answered %', v; END IF;
    -- finish before the bytes arrive
    v := pg_temp.f277_call(u_a, 'supplier_portal', 'supplier_portal', sid_a, format('SELECT public.portal_submission_finish(%L)::text', sub1));
    IF v NOT LIKE 'ERR|%PORTAL_UPLOAD_NOT_STORED%' THEN RAISE EXCEPTION 'FIXTURE 277 UPLOAD: finish without bytes → %', v; END IF;
    -- B cannot store at A's path; A cannot store at another path
    v := pg_temp.f277_call(u_b, 'supplier_portal', 'supplier_portal', sid_b,
        format('INSERT INTO storage.objects (bucket_id, name) VALUES (''portal-uploads'', %L) RETURNING name', path1));
    IF v NOT LIKE 'ERR|42501|%' THEN RAISE EXCEPTION 'FIXTURE 277 UPLOAD: B stored at A''s path → %', v; END IF;
    v := pg_temp.f277_call(u_a, 'supplier_portal', 'supplier_portal', sid_a,
        format('INSERT INTO storage.objects (bucket_id, name) VALUES (''portal-uploads'', %L) RETURNING name', s_a || '/other.pdf'));
    IF v NOT LIKE 'ERR|42501|%' THEN RAISE EXCEPTION 'FIXTURE 277 UPLOAD: A stored at a path no submission named → %', v; END IF;
    v := pg_temp.f277_call(u_a, 'supplier_portal', 'supplier_portal', sid_a,
        format('INSERT INTO storage.objects (bucket_id, name) VALUES (''supplier-attachments'', %L) RETURNING name', path1));
    IF v NOT LIKE 'ERR|42501|%' THEN RAISE EXCEPTION 'FIXTURE 277 UPLOAD: A stored into supplier-attachments → %', v; END IF;
    -- A stores its bytes (the Storage API's insert, read back by RETURNING under the same judge)
    v := pg_temp.f277_call(u_a, 'supplier_portal', 'supplier_portal', sid_a,
        format('INSERT INTO storage.objects (bucket_id, name, owner, metadata) VALUES (''portal-uploads'', %L, %L, %L::jsonb) RETURNING name',
               path1, u_a, '{"size": 12345, "mimetype": "application/pdf"}'));
    IF v <> path1 THEN RAISE EXCEPTION 'FIXTURE 277 UPLOAD: A could not store its own bytes → %', v; END IF;
    -- A cannot change or delete what it stored
    FOREACH v_fn IN ARRAY ARRAY[format('UPDATE storage.objects SET metadata = ''{}''::jsonb WHERE name = %L RETURNING name', path1),
                                format('DELETE FROM storage.objects WHERE name = %L RETURNING name', path1)] LOOP
        v := pg_temp.f277_call(u_a, 'supplier_portal', 'supplier_portal', sid_a, v_fn);
        IF v NOT LIKE 'ERR|42501|%' THEN RAISE EXCEPTION 'FIXTURE 277 UPLOAD: a portal session changed storage (%) → %', v_fn, v; END IF;
    END LOOP;
    v := pg_temp.f277_call(u_b, 'supplier_portal', 'supplier_portal', sid_b, format('SELECT public.portal_submission_finish(%L)::text', sub1));
    IF v NOT LIKE 'ERR|%PORTAL_SUBMISSION_NOT_FOUND%' THEN RAISE EXCEPTION 'FIXTURE 277 UPLOAD: B finished A''s submission → %', v; END IF;
    v := pg_temp.f277_call(u_a, 'supplier_portal', 'supplier_portal', sid_a, format('SELECT public.portal_submission_finish(%L)::text', sub1));
    IF v LIKE 'ERR|%' OR v::jsonb ->> 'state' <> 'waiting' THEN RAISE EXCEPTION 'FIXTURE 277 UPLOAD: finish → %', v; END IF;
    v := pg_temp.f277_call(u_a, 'supplier_portal', 'supplier_portal', sid_a, format('SELECT public.portal_submission_finish(%L)::text', sub1));
    IF v NOT LIKE 'ERR|%PORTAL_SUBMISSION_NOT_UPLOADING|submitted%' THEN RAISE EXCEPTION 'FIXTURE 277 UPLOAD: a second finish → %', v; END IF;
    -- after finishing, the path no longer admits bytes (the judge wants an uploading row)
    v := pg_temp.f277_call(u_a, 'supplier_portal', 'supplier_portal', sid_a, format('SELECT public.portal_can_upload_object(''portal-uploads'', %L)::text', path1));
    IF v <> 'false' THEN RAISE EXCEPTION 'FIXTURE 277 UPLOAD: a finished submission''s path still admits bytes → %', v; END IF;
    -- ONLY: nothing else in public changed
    SELECT string_agg(b.t, ', ') INTO v_bad FROM f277_before b JOIN pg_temp.f277_prints() a ON a.t = b.t WHERE a.h IS DISTINCT FROM b.h;
    IF v_bad IS NOT NULL THEN RAISE EXCEPTION 'FIXTURE 277 ONLY: an upload changed %', v_bad; END IF;
    IF (SELECT count(*) FROM f277_before) < 300 THEN RAISE EXCEPTION 'FIXTURE 277 ONLY: the fingerprint covers only % tables — vacuous', (SELECT count(*) FROM f277_before); END IF;
    IF EXISTS (SELECT 1 FROM change_log c WHERE c.seq > v_cl0 AND c.actor_account = u_a AND c.table_name <> 'portal_certificate_submissions') THEN
        RAISE EXCEPTION 'FIXTURE 277 ONLY: the portal account wrote change-logged rows outside its submissions: %',
            (SELECT string_agg(DISTINCT c.table_name, ', ') FROM change_log c WHERE c.seq > v_cl0 AND c.actor_account = u_a); END IF;
    IF (SELECT count(*) FROM change_log c WHERE c.seq > v_cl0 AND c.table_name = 'portal_certificate_submissions' AND c.row_key ->> 'id' = sub1::text
          AND c.actor_account = u_a) <> 2 THEN
        RAISE EXCEPTION 'FIXTURE 277 ONLY: expected two change-log rows of the submission written by the portal account (begin, finish)'; END IF;

    -- MISMATCH · ABANDON · the ten-minute window
    v := pg_temp.f277_call(u_a, 'supplier_portal', 'supplier_portal', sid_a, format(v_begin, 'nea_import', NULL, NULL, NULL, 'scan.png', 'image/png', 500));
    sub2 := (v::jsonb ->> 'id')::uuid; path2 := v::jsonb ->> 'path';
    v := pg_temp.f277_call(u_a, 'supplier_portal', 'supplier_portal', sid_a,
        format('INSERT INTO storage.objects (bucket_id, name, metadata) VALUES (''portal-uploads'', %L, %L::jsonb) RETURNING name', path2, '{"size": 999, "mimetype": "image/png"}'));
    IF v <> path2 THEN RAISE EXCEPTION 'FIXTURE 277 UPLOAD: storing the second file → %', v; END IF;
    v := pg_temp.f277_call(u_a, 'supplier_portal', 'supplier_portal', sid_a, format('SELECT public.portal_submission_finish(%L)::text', sub2));
    IF v NOT LIKE 'ERR|%PORTAL_UPLOAD_MISMATCH%' THEN RAISE EXCEPTION 'FIXTURE 277 UPLOAD: a size mismatch → %', v; END IF;
    v := pg_temp.f277_call(u_a, 'supplier_portal', 'supplier_portal', sid_a, format('SELECT public.portal_submission_abandon(%L)::text', sub2));
    IF v LIKE 'ERR|%' OR (SELECT status FROM portal_certificate_submissions WHERE id = sub2) <> 'abandoned' THEN RAISE EXCEPTION 'FIXTURE 277 UPLOAD: abandon → %', v; END IF;
    v := pg_temp.f277_call(u_a, 'supplier_portal', 'supplier_portal', sid_a, format('SELECT public.portal_submission_abandon(%L)::text', sub1));
    IF v NOT LIKE 'ERR|%PORTAL_SUBMISSION_NOT_UPLOADING|submitted%' THEN RAISE EXCEPTION 'FIXTURE 277 UPLOAD: abandoning a sent one → %', v; END IF;
    v := pg_temp.f277_call(u_a, 'supplier_portal', 'supplier_portal', sid_a, format(v_begin, 'nea_import', NULL, NULL, NULL, 'late.pdf', 'application/pdf', 500));
    sub3 := (v::jsonb ->> 'id')::uuid;
    UPDATE portal_certificate_submissions SET created_at = now() - interval '11 minutes' WHERE id = sub3;
    v := pg_temp.f277_call(u_a, 'supplier_portal', 'supplier_portal', sid_a,
        format('INSERT INTO storage.objects (bucket_id, name) VALUES (''portal-uploads'', %L) RETURNING name', (SELECT storage_path FROM portal_certificate_submissions WHERE id = sub3)));
    IF v NOT LIKE 'ERR|42501|%' THEN RAISE EXCEPTION 'FIXTURE 277 UPLOAD: a submission registered eleven minutes ago still admits bytes → %', v; END IF;

    -- ── REVIEW (who may) ────────────────────────────────────────────────────
    v_att_path := s_a || '/' || gen_random_uuid() || '-permit.pdf';
    FOREACH v_fn IN ARRAY ARRAY[format('SELECT public.portal_submission_accept(%L, %L, NULL, NULL, NULL, NULL)::text', sub1, v_att_path),
                                format('SELECT public.portal_submission_reject(%L, %L)::text', sub1, 'no')] LOOP
        FOREACH v_other IN ARRAY ARRAY['view', 'none'] LOOP
            v := pg_temp.f277_call(CASE v_other WHEN 'view' THEN u_view ELSE u_none END, 'authenticated', 'authenticated', NULL, v_fn);
            IF v NOT LIKE 'ERR|%PERMISSION_DENIED%' THEN RAISE EXCEPTION 'FIXTURE 277 REVIEW: a % reader reviewed (%) → %', v_other, v_fn, v; END IF;
        END LOOP;
        v := pg_temp.f277_call(u_a, 'supplier_portal', 'supplier_portal', sid_a, v_fn);
        IF v NOT LIKE 'ERR|42501|%' THEN RAISE EXCEPTION 'FIXTURE 277 REVIEW: the portal account reviewed its own submission → %', v; END IF;
    END LOOP;
    v := pg_temp.f277_call(u_view, 'authenticated', 'authenticated', NULL, format('SELECT count(*)::text FROM public.portal_certificate_submissions WHERE supplier_id = %L', s_a));
    IF v <> '3' THEN RAISE EXCEPTION 'FIXTURE 277 REVIEW: a suppliers viewer reads % of A''s 3 submissions', v; END IF;
    v := pg_temp.f277_call(u_none, 'authenticated', 'authenticated', NULL, 'SELECT count(*)::text FROM public.portal_certificate_submissions');
    IF v <> '0' THEN RAISE EXCEPTION 'FIXTURE 277 REVIEW: a reader without module.suppliers.view reads % submission(s)', v; END IF;
    v := pg_temp.f277_call(u_a, 'supplier_portal', 'supplier_portal', sid_a, 'SELECT count(*)::text FROM public.portal_certificate_submissions');
    IF v NOT LIKE 'ERR|42501|%' THEN RAISE EXCEPTION 'FIXTURE 277 REVIEW: a portal session reads the submissions table directly → %', v; END IF;
    v := pg_temp.f277_call(u_view, 'authenticated', 'authenticated', NULL, format('SELECT count(*)::text FROM storage.objects WHERE bucket_id = ''portal-uploads'' AND name = %L', path1));
    IF v <> '1' THEN RAISE EXCEPTION 'FIXTURE 277 REVIEW: a suppliers viewer cannot see the submitted file (%)', v; END IF;
    v := pg_temp.f277_call(u_none, 'authenticated', 'authenticated', NULL, 'SELECT count(*)::text FROM storage.objects WHERE bucket_id = ''portal-uploads''');
    IF v <> '0' THEN RAISE EXCEPTION 'FIXTURE 277 REVIEW: a reader without module.suppliers.view sees % submitted file(s)', v; END IF;

    -- ── ACCEPT ─────────────────────────────────────────────────────────────
    v := pg_temp.f277_call(u_edit, 'authenticated', 'authenticated', NULL, format('SELECT public.portal_submission_accept(%L, %L, NULL, NULL, NULL, NULL)::text', sub1, v_att_path));
    IF v NOT LIKE 'ERR|%PORTAL_SUBMISSION_FILE_NOT_COPIED%' THEN RAISE EXCEPTION 'FIXTURE 277 ACCEPT: accepted without the copy → %', v; END IF;
    v := pg_temp.f277_call(u_edit, 'authenticated', 'authenticated', NULL, format('SELECT public.portal_submission_accept(%L, %L, NULL, NULL, NULL, NULL)::text', sub1, s_b || '/x-permit.pdf'));
    IF v NOT LIKE 'ERR|%PORTAL_SUBMISSION_FILE_PATH_INVALID%' THEN RAISE EXCEPTION 'FIXTURE 277 ACCEPT: a copy in another supplier''s folder → %', v; END IF;
    -- the staff session copies the file (the Storage API's copy = an insert into supplier-attachments under module.suppliers.edit)
    v := pg_temp.f277_call(u_edit, 'authenticated', 'authenticated', NULL,
        format('INSERT INTO storage.objects (bucket_id, name, metadata) VALUES (''supplier-attachments'', %L, %L::jsonb) RETURNING name', v_att_path, '{"size": 12345, "mimetype": "application/pdf"}'));
    IF v <> v_att_path THEN RAISE EXCEPTION 'FIXTURE 277 ACCEPT: the staff copy into supplier-attachments → %', v; END IF;
    CREATE TEMP TABLE f277_mid ON COMMIT DROP AS SELECT * FROM pg_temp.f277_prints();
    v := pg_temp.f277_call(u_edit, 'authenticated', 'authenticated', NULL,
        format('SELECT public.portal_submission_accept(%L, %L, %L, %L, NULL, %L::date)::text', sub1, v_att_path, 'NEA-277-CHECKED', 'NEA', '2027-06-30'));
    IF v LIKE 'ERR|%' THEN RAISE EXCEPTION 'FIXTURE 277 ACCEPT: accept → %', v; END IF;
    v_j := v::jsonb;
    IF NOT EXISTS (SELECT 1 FROM supplier_compliance c WHERE c.id = (v_j ->> 'compliance_id')::uuid AND c.supplier_id = s_a AND c.cert_type_code = 'nea_import'
                    AND c.cert_no = 'NEA-277-CHECKED' AND c.issuing_body = 'NEA' AND c.valid_from = DATE '2026-01-01' AND c.valid_until = DATE '2027-06-30'
                    AND c.document_id = (v_j ->> 'attachment_id')::uuid AND c.created_by = u_edit AND c.deleted_at IS NULL) THEN
        RAISE EXCEPTION 'FIXTURE 277 ACCEPT: the supplier_compliance row is missing or wrong'; END IF;
    IF NOT EXISTS (SELECT 1 FROM supplier_attachments a WHERE a.id = (v_j ->> 'attachment_id')::uuid AND a.supplier_id = s_a AND a.storage_path = v_att_path
                    AND a.file_name = 'permit.pdf' AND a.file_size = 12345) THEN
        RAISE EXCEPTION 'FIXTURE 277 ACCEPT: the supplier_attachments row is missing or wrong'; END IF;
    IF NOT EXISTS (SELECT 1 FROM portal_certificate_submissions s WHERE s.id = sub1 AND s.status = 'accepted' AND s.decided_by = u_edit
                    AND s.compliance_id = (v_j ->> 'compliance_id')::uuid AND s.attachment_id = (v_j ->> 'attachment_id')::uuid) THEN
        RAISE EXCEPTION 'FIXTURE 277 ACCEPT: the submission is not accepted with both links'; END IF;
    -- accepting touched exactly the two tables Q19 names (compliance, attachments) beyond the submission
    SELECT string_agg(b.t, ', ' ORDER BY b.t) INTO v_bad FROM f277_mid b JOIN pg_temp.f277_prints() a ON a.t = b.t WHERE a.h IS DISTINCT FROM b.h;
    IF v_bad IS DISTINCT FROM 'supplier_attachments, supplier_compliance' THEN RAISE EXCEPTION 'FIXTURE 277 ACCEPT: accepting changed % (expected the compliance and attachment rows only)', v_bad; END IF;
    v := pg_temp.f277_call(u_edit, 'authenticated', 'authenticated', NULL, format('SELECT public.portal_submission_accept(%L, %L, NULL, NULL, NULL, NULL)::text', sub1, v_att_path));
    IF v NOT LIKE 'ERR|%PORTAL_SUBMISSION_NOT_WAITING|accepted%' THEN RAISE EXCEPTION 'FIXTURE 277 ACCEPT: a second accept → %', v; END IF;
    v := pg_temp.f277_call(u_a, 'supplier_portal', 'supplier_portal', sid_a, 'SELECT public.portal_certificates()::text');
    v_j := v::jsonb;
    IF (SELECT x ->> 'state' FROM jsonb_array_elements(v_j -> 'submissions') x WHERE x ->> 'id' = sub1::text) IS DISTINCT FROM 'accepted'
       OR NOT EXISTS (SELECT 1 FROM jsonb_array_elements(v_j -> 'compliance') x WHERE x ->> 'cert_no' = 'NEA-277-CHECKED' AND x ->> 'valid_until' = '2027-06-30') THEN
        RAISE EXCEPTION 'FIXTURE 277 ACCEPT: the portal does not show the acceptance → %', left(v, 400); END IF;
    IF v ~ '(abandoned|uploading|late\.pdf|scan\.png|decided_by|NEA"|issuing)' THEN
        RAISE EXCEPTION 'FIXTURE 277 ACCEPT: the portal lists an unfinished upload or a staff field → %', left(v, 400); END IF;

    -- ── REJECT ─────────────────────────────────────────────────────────────
    v := pg_temp.f277_call(u_a, 'supplier_portal', 'supplier_portal', sid_a, format(v_begin, 'basel', 'B-1', NULL, NULL, 'basel.jpg', 'image/jpeg', 700));
    sub4 := (v::jsonb ->> 'id')::uuid; path4 := v::jsonb ->> 'path';
    PERFORM pg_temp.f277_call(u_a, 'supplier_portal', 'supplier_portal', sid_a,
        format('INSERT INTO storage.objects (bucket_id, name, metadata) VALUES (''portal-uploads'', %L, %L::jsonb) RETURNING name', path4, '{"size": 700, "mimetype": "image/jpeg"}'));
    v := pg_temp.f277_call(u_a, 'supplier_portal', 'supplier_portal', sid_a, format('SELECT public.portal_submission_finish(%L)::text', sub4));
    IF v LIKE 'ERR|%' THEN RAISE EXCEPTION 'FIXTURE 277 REJECT: sending the second certificate → %', v; END IF;
    CREATE TEMP TABLE f277_rej ON COMMIT DROP AS SELECT * FROM pg_temp.f277_prints();
    v := pg_temp.f277_call(u_edit, 'authenticated', 'authenticated', NULL, format('SELECT public.portal_submission_reject(%L, %L)::text', sub4, '   '));
    IF v NOT LIKE 'ERR|%PORTAL_SUBMISSION_REASON_REQUIRED%' THEN RAISE EXCEPTION 'FIXTURE 277 REJECT: a blank reason → %', v; END IF;
    v := pg_temp.f277_call(u_edit, 'authenticated', 'authenticated', NULL, format('SELECT public.portal_submission_reject(%L, %L)::text', sub4, 'FX277 the scan is unreadable'));
    IF v LIKE 'ERR|%' THEN RAISE EXCEPTION 'FIXTURE 277 REJECT: reject → %', v; END IF;
    IF NOT EXISTS (SELECT 1 FROM portal_certificate_submissions WHERE id = sub4 AND status = 'rejected' AND reject_reason = 'FX277 the scan is unreadable'
                    AND decided_by = u_edit AND compliance_id IS NULL AND attachment_id IS NULL) THEN
        RAISE EXCEPTION 'FIXTURE 277 REJECT: the submission is not rejected with its reason'; END IF;
    SELECT string_agg(b.t, ', ') INTO v_bad FROM f277_rej b JOIN pg_temp.f277_prints() a ON a.t = b.t WHERE a.h IS DISTINCT FROM b.h;
    IF v_bad IS NOT NULL THEN RAISE EXCEPTION 'FIXTURE 277 REJECT: rejecting changed %', v_bad; END IF;
    v := pg_temp.f277_call(u_a, 'supplier_portal', 'supplier_portal', sid_a, 'SELECT public.portal_certificates()::text');
    IF (SELECT x ->> 'state' || '|' || (x ->> 'reject_reason') FROM jsonb_array_elements(v::jsonb -> 'submissions') x WHERE x ->> 'id' = sub4::text)
       IS DISTINCT FROM 'rejected|FX277 the scan is unreadable' THEN
        RAISE EXCEPTION 'FIXTURE 277 REJECT: the supplier does not see the reason → %', left(v, 400); END IF;
    v := pg_temp.f277_call(u_edit, 'authenticated', 'authenticated', NULL, format('SELECT public.portal_submission_reject(%L, %L)::text', sub4, 'again'));
    IF v NOT LIKE 'ERR|%PORTAL_SUBMISSION_NOT_WAITING|rejected%' THEN RAISE EXCEPTION 'FIXTURE 277 REJECT: a second reject → %', v; END IF;

    -- ── EVERY (two suppliers; B sends one waiting certificate of its own) ───
    v := pg_temp.f277_call(u_b, 'supplier_portal', 'supplier_portal', sid_b, format(v_begin, 'nea_import', 'FX277-SB-N', NULL, NULL, 'b.pdf', 'application/pdf', 300));
    sub_b := (v::jsonb ->> 'id')::uuid; path_b := v::jsonb ->> 'path';
    PERFORM pg_temp.f277_call(u_b, 'supplier_portal', 'supplier_portal', sid_b,
        format('INSERT INTO storage.objects (bucket_id, name, metadata) VALUES (''portal-uploads'', %L, %L::jsonb) RETURNING name', path_b, '{"size": 300, "mimetype": "application/pdf"}'));
    v := pg_temp.f277_call(u_b, 'supplier_portal', 'supplier_portal', sid_b, format('SELECT public.portal_submission_finish(%L)::text', sub_b));
    IF v LIKE 'ERR|%' THEN RAISE EXCEPTION 'FIXTURE 277 EVERY: B sends → %', v; END IF;
    -- a fresh uploading row each for A and B, for the begin / finish / abandon / can_upload cases
    v := pg_temp.f277_call(u_a, 'supplier_portal', 'supplier_portal', sid_a, format(v_begin, 'nea_import', NULL, NULL, NULL, 'a5.pdf', 'application/pdf', 100));
    sub5 := (v::jsonb ->> 'id')::uuid; path5 := v::jsonb ->> 'path';
    v := pg_temp.f277_call(u_b, 'supplier_portal', 'supplier_portal', sid_b, format(v_begin, 'nea_import', NULL, NULL, NULL, 'b5.pdf', 'application/pdf', 100));
    sub2 := (v::jsonb ->> 'id')::uuid; path2 := v::jsonb ->> 'path';
    -- and one each whose bytes are already stored, for the finish case (abandon runs before finish in catalogue order)
    v := pg_temp.f277_call(u_a, 'supplier_portal', 'supplier_portal', sid_a, format(v_begin, 'nea_import', NULL, NULL, NULL, 'a6.pdf', 'application/pdf', 60));
    sub6 := (v::jsonb ->> 'id')::uuid; path6 := v::jsonb ->> 'path';
    PERFORM pg_temp.f277_call(u_a, 'supplier_portal', 'supplier_portal', sid_a,
        format('INSERT INTO storage.objects (bucket_id, name, metadata) VALUES (''portal-uploads'', %L, %L::jsonb) RETURNING name', path6, '{"size": 60, "mimetype": "application/pdf"}'));
    v := pg_temp.f277_call(u_b, 'supplier_portal', 'supplier_portal', sid_b, format(v_begin, 'nea_import', NULL, NULL, NULL, 'b6.pdf', 'application/pdf', 70));
    sub7 := (v::jsonb ->> 'id')::uuid; path7 := v::jsonb ->> 'path';
    PERFORM pg_temp.f277_call(u_b, 'supplier_portal', 'supplier_portal', sid_b,
        format('INSERT INTO storage.objects (bucket_id, name, metadata) VALUES (''portal-uploads'', %L, %L::jsonb) RETURNING name', path7, '{"size": 70, "mimetype": "application/pdf"}'));
    IF (SELECT count(*) FROM storage.objects WHERE name IN (path6, path7)) <> 2 THEN RAISE EXCEPTION 'FIXTURE 277 EVERY: setting up the finish case stored % of 2 files', (SELECT count(*) FROM storage.objects WHERE name IN (path6, path7)); END IF;
    v_cases := jsonb_build_object(
        'portal_certificates()', jsonb_build_array('SELECT public.portal_certificates()::text', 'SELECT public.portal_certificates()::text'),
        'portal_submission_begin(p_cert_type text, p_file_name text, p_file_type text, p_file_size bigint, p_cert_no text, p_valid_from date, p_valid_until date)',
            jsonb_build_array(format(v_begin, 'nea_import', NULL, NULL, NULL, 'e.pdf', 'application/pdf', 10), format(v_begin, 'nea_import', NULL, NULL, NULL, 'e.pdf', 'application/pdf', 10)),
        'portal_submission_finish(p_submission_id uuid)',
            jsonb_build_array(format('SELECT public.portal_submission_finish(%L)::text', sub6), format('SELECT public.portal_submission_finish(%L)::text', sub7)),
        'portal_submission_abandon(p_submission_id uuid)',
            jsonb_build_array(format('SELECT public.portal_submission_abandon(%L)::text', sub5), format('SELECT public.portal_submission_abandon(%L)::text', sub2)),
        'portal_can_upload_object(p_bucket text, p_name text)',
            jsonb_build_array(format('SELECT public.portal_can_upload_object(''portal-uploads'', %L)::text', path5),
                              format('SELECT public.portal_can_upload_object(''portal-uploads'', %L)::text', path2)));
    v_n := 0; v_m := 0;
    FOR r IN SELECT p.oid::regprocedure::text AS sig, p.proname || '(' || pg_get_function_identity_arguments(p.oid) || ')' AS key
               FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
              WHERE n.nspname = 'public' AND has_function_privilege('supplier_portal', p.oid, 'EXECUTE') ORDER BY 1 LOOP
        IF r.key = ANY (v_before) THEN v_m := v_m + 1; CONTINUE; END IF;
        IF NOT v_cases ? r.key THEN
            RAISE EXCEPTION 'FIXTURE 277 EVERY: % is executable by supplier_portal and has no two-supplier case here, in 275 or in 276', r.sig; END IF;
        v_n := v_n + 1;
        -- the other supplier's case, called by this supplier → refused / false (run before the own case consumes the uploading rows)
        FOR k IN 0..1 LOOP
            IF r.key LIKE 'portal_certificates%' OR r.key LIKE 'portal_submission_begin%' THEN CONTINUE; END IF;
            v := pg_temp.f277_call(CASE k WHEN 0 THEN u_a ELSE u_b END, 'supplier_portal', 'supplier_portal', CASE k WHEN 0 THEN sid_a ELSE sid_b END,
                                   v_cases -> r.key ->> (1 - k));
            IF r.key LIKE 'portal_can_upload_object%' THEN
                IF v <> 'false' THEN RAISE EXCEPTION 'FIXTURE 277 EVERY: % — % reads the other supplier''s path as uploadable → %', r.sig, k, v; END IF;
            ELSIF v NOT LIKE 'ERR|%PORTAL_SUBMISSION_NOT_FOUND%' THEN
                RAISE EXCEPTION 'FIXTURE 277 EVERY: % — % on the other supplier''s submission → %', r.sig, k, v; END IF;
        END LOOP;
        -- refusals first (they must not consume anything): staff session · staff code holder · wrong claim · ended · no session · not portal · banned
        v_fn := v_cases -> r.key ->> 0;
        v := pg_temp.f277_call(u_a, 'authenticated', 'authenticated', sid_a, v_fn);
        IF v NOT LIKE 'ERR|42501|%' THEN RAISE EXCEPTION 'FIXTURE 277 EVERY: % as authenticated — %', r.sig, left(v, 200); END IF;
        v := pg_temp.f277_call(u_edit, 'authenticated', 'authenticated', NULL, v_fn);
        IF v NOT LIKE 'ERR|42501|%' THEN RAISE EXCEPTION 'FIXTURE 277 EVERY: % as a staff code holder — %', r.sig, left(v, 200); END IF;
        FOR v_other IN SELECT * FROM unnest(ARRAY['claim', 'ended', 'nosession', 'notportal', 'banned']) LOOP
            IF v_other = 'banned' THEN UPDATE auth.users SET banned_until = now() + interval '1 day' WHERE id = u_a; END IF;
            v := pg_temp.f277_call(CASE v_other WHEN 'notportal' THEN u_x ELSE u_a END, 'supplier_portal',
                                   CASE v_other WHEN 'claim' THEN 'authenticated' ELSE 'supplier_portal' END,
                                   CASE v_other WHEN 'ended' THEN gen_random_uuid() WHEN 'nosession' THEN NULL WHEN 'notportal' THEN sid_x ELSE sid_a END, v_fn);
            IF v_other = 'banned' THEN UPDATE auth.users SET banned_until = NULL WHERE id = u_a; END IF;
            IF r.key LIKE 'portal_can_upload_object%' THEN
                IF v <> 'false' THEN RAISE EXCEPTION 'FIXTURE 277 EVERY: % (%) must answer false, never raise → %', r.sig, v_other, v; END IF;
            ELSIF v NOT LIKE '%' || (CASE v_other WHEN 'claim' THEN 'PORTAL_ROLE_REQUIRED' WHEN 'ended' THEN 'PORTAL_SESSION_ENDED'
                                                  WHEN 'nosession' THEN 'PORTAL_SESSION_ENDED' WHEN 'notportal' THEN 'PORTAL_NOT_A_PORTAL_ACCOUNT'
                                                  ELSE 'PORTAL_ACCESS_REVOKED' END) || '%' THEN
                RAISE EXCEPTION 'FIXTURE 277 EVERY: % (%) → %', r.sig, v_other, left(v, 200); END IF;
        END LOOP;
        -- A, then B: each answered with its own, nothing of the other
        FOR k IN 0..1 LOOP
            v := pg_temp.f277_call(CASE k WHEN 0 THEN u_a ELSE u_b END, 'supplier_portal', 'supplier_portal', CASE k WHEN 0 THEN sid_a ELSE sid_b END,
                                   v_cases -> r.key ->> k);
            IF r.key LIKE 'portal_certificates%' THEN
                IF v LIKE 'ERR|%' OR v NOT LIKE (CASE k WHEN 0 THEN '%FX277-SA%' ELSE '%FX277-SB%' END)
                   OR v LIKE (CASE k WHEN 0 THEN '%FX277-SB%' ELSE '%FX277-SA%' END)
                   OR (k = 0 AND v NOT LIKE '%NEA-277-CHECKED%') OR (k = 1 AND (v LIKE '%NEA-277%' OR v LIKE '%unreadable%' OR v NOT LIKE '%FX277-SB-N%')) THEN
                    RAISE EXCEPTION 'FIXTURE 277 EVERY: % as % → %', r.sig, CASE k WHEN 0 THEN 'A' ELSE 'B' END, left(v, 400); END IF;
            ELSIF r.key LIKE 'portal_submission_begin%' THEN
                IF v LIKE 'ERR|%' OR (v::jsonb ->> 'path') NOT LIKE (CASE k WHEN 0 THEN s_a ELSE s_b END)::text || '/%'
                   OR (SELECT supplier_id FROM portal_certificate_submissions WHERE id = (v::jsonb ->> 'id')::uuid) <> (CASE k WHEN 0 THEN s_a ELSE s_b END) THEN
                    RAISE EXCEPTION 'FIXTURE 277 EVERY: % as % registered a submission for the wrong supplier → %', r.sig, k, v; END IF;
            ELSIF r.key LIKE 'portal_can_upload_object%' THEN
                IF v <> 'true' THEN RAISE EXCEPTION 'FIXTURE 277 EVERY: % as % on its own uploading path → %', r.sig, k, v; END IF;
            ELSIF r.key LIKE 'portal_submission_finish%' THEN
                IF v LIKE 'ERR|%' OR v::jsonb ->> 'state' <> 'waiting'
                   OR (SELECT status FROM portal_certificate_submissions WHERE id = CASE k WHEN 0 THEN sub6 ELSE sub7 END) <> 'submitted' THEN
                    RAISE EXCEPTION 'FIXTURE 277 EVERY: % as % on its own submission → %', r.sig, k, v; END IF;
            ELSIF r.key LIKE 'portal_submission_abandon%' THEN
                IF v LIKE 'ERR|%' OR (SELECT status FROM portal_certificate_submissions WHERE id = CASE k WHEN 0 THEN sub5 ELSE sub2 END) <> 'abandoned' THEN
                    RAISE EXCEPTION 'FIXTURE 277 EVERY: % as % → %', r.sig, k, v; END IF;
            END IF;
        END LOOP;
    END LOOP;
    IF v_n <> 5 OR v_m <> cardinality(v_before) THEN
        RAISE EXCEPTION 'FIXTURE 277 EVERY: % MES-9c function(s) here (expected 5) and % earlier portal function(s) in 275 / 276 (expected %) — the catalogue and the three fixtures disagree',
            v_n, v_m, cardinality(v_before); END IF;
    IF (SELECT count(*) FROM portal_certificate_submissions WHERE supplier_id = s_b AND status = 'submitted') <> 2 THEN
        RAISE EXCEPTION 'FIXTURE 277 EVERY: B should have exactly its two waiting submissions'; END IF;

    -- ── GRANTS ─────────────────────────────────────────────────────────────
    FOREACH v IN ARRAY ARRAY['public.portal_certificates()', 'public.portal_submission_begin(text,text,text,bigint,text,date,date)',
                             'public.portal_submission_finish(uuid)', 'public.portal_submission_abandon(uuid)', 'public.portal_can_upload_object(text,text)'] LOOP
        IF NOT has_function_privilege('supplier_portal', v::regprocedure, 'EXECUTE')
           OR has_function_privilege('authenticated', v::regprocedure, 'EXECUTE')
           OR has_function_privilege('anon', v::regprocedure, 'EXECUTE')
           OR NOT (SELECT prosecdef FROM pg_proc WHERE oid = v::regprocedure) THEN
            RAISE EXCEPTION 'FIXTURE 277 GRANTS: % must be SECURITY DEFINER and executable by supplier_portal only', v; END IF;
    END LOOP;
    FOREACH v IN ARRAY ARRAY['public.portal_submission_accept(uuid,text,text,text,date,date)', 'public.portal_submission_reject(uuid,text)'] LOOP
        IF has_function_privilege('supplier_portal', v::regprocedure, 'EXECUTE') OR has_function_privilege('anon', v::regprocedure, 'EXECUTE')
           OR NOT has_function_privilege('authenticated', v::regprocedure, 'EXECUTE') THEN
            RAISE EXCEPTION 'FIXTURE 277 GRANTS: % must be executable by authenticated (it checks module.suppliers.edit) and not by the portal or anon', v; END IF;
    END LOOP;
    IF NOT has_table_privilege('supplier_portal', 'storage.objects', 'INSERT')
       OR has_table_privilege('supplier_portal', 'storage.objects', 'UPDATE') OR has_table_privilege('supplier_portal', 'storage.objects', 'DELETE')
       OR has_table_privilege('supplier_portal', 'public.portal_certificate_submissions', 'SELECT,INSERT,UPDATE,DELETE')
       OR has_table_privilege('authenticated', 'public.portal_certificate_submissions', 'INSERT,UPDATE,DELETE,TRUNCATE')
       OR has_table_privilege('anon', 'public.portal_certificate_submissions', 'SELECT,INSERT,UPDATE,DELETE,TRUNCATE') THEN
        RAISE EXCEPTION 'FIXTURE 277 GRANTS: storage.objects INSERT for the portal (no UPDATE / DELETE); the submissions table SELECT-only for authenticated, nothing for the portal or anon'; END IF;
    IF (SELECT count(*) FROM pg_policies WHERE schemaname = 'storage' AND 'supplier_portal' = ANY (roles)) <> 3
       OR NOT EXISTS (SELECT 1 FROM pg_policies WHERE schemaname = 'storage' AND policyname = 'portal uploads its own pending submission file'
                       AND cmd = 'INSERT' AND roles = ARRAY['supplier_portal']::name[] AND with_check ~ 'portal_can_upload_object\(bucket_id, name\)')
       OR NOT EXISTS (SELECT 1 FROM pg_policies WHERE schemaname = 'storage' AND policyname = 'portal reads its own pending submission file'
                       AND cmd = 'SELECT' AND roles = ARRAY['supplier_portal']::name[] AND qual ~ 'portal_can_upload_object\(bucket_id, name\)')
       OR EXISTS (SELECT 1 FROM pg_policies WHERE schemaname = 'storage' AND COALESCE(qual, '') || COALESCE(with_check, '') LIKE '%portal-uploads%' AND cmd IN ('UPDATE', 'DELETE', 'ALL')) THEN
        RAISE EXCEPTION 'FIXTURE 277 GRANTS: the portal-uploads policies are not the two portal ones by name plus a staff read, with no update or delete'; END IF;

    -- ── TRAIL ──────────────────────────────────────────────────────────────
    v_j := trail_actor('user', u_a, NULL);
    IF v_j ->> 'state' <> 'portal' OR v_j ->> 'name' <> 'fixture 277 supplier A' THEN
        RAISE EXCEPTION 'FIXTURE 277 TRAIL: trail_actor for the portal account that sent a certificate is %', v_j; END IF;
    IF NOT EXISTS (SELECT 1 FROM change_log c WHERE c.table_name = 'portal_certificate_submissions' AND c.row_key ->> 'id' = sub4::text
                    AND c.actor_account = u_edit AND c.new ->> 'status' = 'rejected' AND c.new ->> 'reject_reason' = 'FX277 the scan is unreadable') THEN
        RAISE EXCEPTION 'FIXTURE 277 TRAIL: the rejection with its reason is not in the change log under the reviewer'; END IF;
    IF NOT EXISTS (SELECT 1 FROM trail_subject_members() m WHERE m.subject = 'supplier' AND m.table_name = 'portal_certificate_submissions'
                    AND m.parent_table = 'suppliers' AND m.fk_column = 'supplier_id' AND m.home AND m.shown) THEN
        RAISE EXCEPTION 'FIXTURE 277 TRAIL: the submissions are not members of the supplier''s trail'; END IF;

    -- ── EXCL ───────────────────────────────────────────────────────────────
    v_j := change_log_coverage_gaps();
    IF jsonb_array_length(v_j -> 'gaps') <> 0 OR (v_j ->> 'excluded')::int <> 12 THEN
        RAISE EXCEPTION 'FIXTURE 277 EXCL: change-log coverage %', v_j; END IF;
    IF EXISTS (SELECT 1 FROM change_log_exclusions() x WHERE x.table_name = 'portal_certificate_submissions') THEN
        RAISE EXCEPTION 'FIXTURE 277 EXCL: the submissions table is excluded from the change log'; END IF;
    IF EXISTS (SELECT 1 FROM change_log_mask_rules() m WHERE m.table_name = 'portal_certificate_submissions') THEN
        RAISE EXCEPTION 'FIXTURE 277 EXCL: a column of the submissions table is masked'; END IF;

    RAISE NOTICE 'FIXTURE 277 全部通过: V39 · ONLY · UPLOAD · REVIEW · ACCEPT · REJECT · EVERY · GRANTS · TRAIL · EXCL';
END
$f277$;
ROLLBACK;

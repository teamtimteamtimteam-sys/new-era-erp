-- ═══════════════════════════════════════════════════════════════════════════
-- fixture 306 —— 一份合同的电子文件:草稿与生效中的合同上传 / 替换,只有签署人名单上的人、刚重新输入过密码、
--   在【生效中】的合同上签得了,签过就锁住,作废要理由,对方签回件是最终版本(CONTRACT-ESIGN,Tim 2026-10-29 · 2026-10-30 Q1–Q12)
-- ═══════════════════════════════════════════════════════════════════════════
-- 臂:
--   P        新码 action.manage_signatories 在目录里、声明了查看码、引导只授 admin
--   L        名单:没有码的人加不了;有码的人加得了;同一人重复 / 没有登录账号 / 职衔空各自按名拒;移除只记时刻、移除两次按名拒;再加是新的一行;
--            每一次都进变更记录
--   S        签字样本:只有【本人】、而且在名单上,传得进 specimens/<自己的员工 id>/,登记得了;别人的路径、admin(Q4)、不在名单上的人都不行;
--            换一张,旧的记 superseded_at;守卫挡住改别的列
--   T        公司印章:只有持 action.manage_signatories 的人传、登记;签署人读得到,别人读不到;换一张留历史
--   U        上传未签文件:要 action.contract_terms + 读得到;草稿 / 生效中可以,暂停 / 到期不行(Q1);只收 PDF、25 MB(Q12);
--            存储只放行自己登记的那一条路径;finish 比大小与类型;替换时旧的记 superseded(A)
--   R        读(Q8):只持那一侧读码、不持价格码的人读不到那一行,也读不到那个对象;两样都持的读得到
--   G        签:草稿 / 暂停按名拒(Q1);不在名单上、没有重新输入密码(令牌里没有 amr 的 password 项,或已经过了 5 分钟)、没有样本、
--            选了印章而没有印章、位置不对,各自按名拒;过了 → 一行 signed,记下签署人、名字与职衔、样本、印章、位置、密码时刻;
--            存下之后:同一份不能再签(Q9),原件不能替换(D),被替换的原件签不了
--   I        守卫:存下的一份改不了哈希、删不掉;作废不带理由由约束挡住
--   C        对方签回件:不持 contract_terms 的人传不了;先签后传(Q10);传上来那天 signed_on 填上(Q2);它是最终版本
--   V        作废(Q7):不在名单上、不持码的人不行;理由空按名拒;作废签过版本连带作废签回件;作废之后能替换原件、能重新签;
--            admin(持码、不在名单上)作废得了;移除签署人不作废他签过的
--   X        合同被删(只有属主路径)→ 它的文件随之删掉;别的删除一律挡
-- 前提:db/gate.py 已把 storage 桩与 db/storage/buckets-and-policies.sql 装进了这个重建库。自带数据(README 第 2 条)。
-- 注入(记录在 docs/surveys/CONTRACT-ESIGN/readings/fixture-306-injections.txt):
--   ① contract_file_readable 恒回 true → U 臂红(读不到价格的人传得了);② contract_sign_begin 拿掉密码那一条 → G 臂红。
-- ═══════════════════════════════════════════════════════════════════════════

BEGIN;
SET LOCAL statement_timeout = '300s';

-- 会话:p_pw_age = 令牌里 amr 的 password 项是多少秒以前(NULL = 没有这一项)
CREATE FUNCTION pg_temp.f306_as(p_user uuid, p_pw_age int DEFAULT NULL) RETURNS void
LANGUAGE sql AS $f$
    SELECT set_config('request.jwt.claims',
        CASE WHEN p_user IS NULL THEN ''
             WHEN p_pw_age IS NULL THEN format('{"sub":"%s","role":"authenticated"}', p_user)
             ELSE format('{"sub":"%s","role":"authenticated","amr":[{"method":"password","timestamp":%s}]}',
                         p_user, floor(extract(epoch FROM now()) - p_pw_age)::bigint) END, true)
$f$;

-- 以 p_user 调一句(属主权限函数,不必切角色),回结果或 'ERR|<错>'
CREATE FUNCTION pg_temp.f306_call(p_user uuid, p_sql text, p_pw_age int DEFAULT NULL) RETURNS text
LANGUAGE plpgsql AS $f$
DECLARE v text;
BEGIN
    PERFORM pg_temp.f306_as(p_user, p_pw_age);
    BEGIN EXECUTE p_sql INTO v; EXCEPTION WHEN OTHERS THEN v := 'ERR|' || SQLERRM; END;
    PERFORM pg_temp.f306_as(NULL);
    RETURN COALESCE(v, '<null>');
END;
$f$;

-- 以 p_user、切成 authenticated 跑一句:SELECT 回第一列(数),别的回影响行数;被拒回 -1
CREATE FUNCTION pg_temp.f306_rc(p_user uuid, p_sql text) RETURNS bigint
LANGUAGE plpgsql AS $f$
DECLARE v bigint;
BEGIN
    PERFORM pg_temp.f306_as(p_user);
    EXECUTE 'SET LOCAL ROLE authenticated';
    BEGIN
        IF p_sql ~* '^\s*select' THEN EXECUTE p_sql INTO v;
        ELSE EXECUTE p_sql; GET DIAGNOSTICS v = ROW_COUNT; END IF;
    EXCEPTION WHEN OTHERS THEN v := -1; END;
    EXECUTE 'RESET ROLE';
    PERFORM pg_temp.f306_as(NULL);
    RETURN v;
END;
$f$;

CREATE FUNCTION pg_temp.f306_role(p_code text, p_codes text[]) RETURNS uuid
LANGUAGE sql AS $f$
    WITH r AS (INSERT INTO roles (code, name_en, name_zh, is_active) VALUES (p_code, 'f', 'f', true) RETURNING id),
         g AS (INSERT INTO role_permissions (role_id, permission_code) SELECT r.id, c FROM r, unnest(p_codes) c RETURNING role_id)
    SELECT id FROM r
$f$;

-- 一个对象"传上去了"(存储桩:直接写 storage.objects 的那一行 —— Storage API 的那一半只有线上证明答得了)
CREATE FUNCTION pg_temp.f306_put(p_user uuid, p_bucket text, p_name text, p_size bigint, p_type text) RETURNS bigint
LANGUAGE sql AS $f$
    SELECT pg_temp.f306_rc(p_user, format('INSERT INTO storage.objects (bucket_id, name, metadata) VALUES (%L, %L, %L)',
                                          p_bucket, p_name, jsonb_build_object('size', p_size, 'mimetype', p_type)))
$f$;

DO $f306$
DECLARE
    u_admin uuid := gen_random_uuid();   -- 全部码(含 action.manage_signatories),没有员工档案
    u_cco   uuid := gen_random_uuid();   -- action.contract_terms + 两侧读码与价格码,不在名单上
    u_sig   uuid := gen_random_uuid();   -- 签署人:两侧读码与价格码,不持 contract_terms
    u_sig2  uuid := gen_random_uuid();   -- 第二名签署人:还没有样本
    u_other uuid := gen_random_uuid();   -- 有员工档案、读得到合同、不在名单上
    u_wh    uuid := gen_random_uuid();   -- 只持 module.suppliers.view(没有采购价码)
    u_cv    uuid := gen_random_uuid();   -- 只持 module.customers.view(没有销售价码)
    u_term_nobuy uuid := gen_random_uuid();   -- contract_terms + suppliers.view,没有采购价码
    e_sig uuid; e_sig2 uuid; e_other uuid; e_nologin uuid;
    v_cust uuid; v_sup uuid;
    c_act uuid; c_draft uuid; c_buy uuid; c_susp uuid; c_exp uuid;
    code_act text; code_draft text;
    s_sig uuid; s_sig2 uuid; s_tmp uuid;
    sp1 uuid := gen_random_uuid(); sp2 uuid := gen_random_uuid(); st1 uuid := gen_random_uuid(); st2 uuid := gen_random_uuid(); sp3 uuid := gen_random_uuid();
    v text; v_res jsonb; v_n bigint;
    f1 uuid; f1p text; f2 uuid; f2p text; fb uuid; fbp text; sg1 uuid; sg1p text; cs1 uuid; cs1p text; sg2 uuid; sg2p text; f3 uuid; f3p text;
    h1 text := repeat('a', 64); h2 text := repeat('b', 64); h3 text := repeat('c', 64);
    all_read text[] := ARRAY['module.customers.view', 'module.suppliers.view', 'data.view_prices', 'data.view_purchase_prices'];
BEGIN
    IF NOT EXISTS (SELECT 1 FROM storage.buckets WHERE id = 'contract-files' AND file_size_limit = 26214400 AND allowed_mime_types = ARRAY['application/pdf'])
       OR NOT EXISTS (SELECT 1 FROM storage.buckets WHERE id = 'signing-assets' AND allowed_mime_types = ARRAY['image/png']) THEN
        RAISE EXCEPTION 'FIXTURE 306 布景失败:重建库里没有 contract-files(25 MB · PDF)/ signing-assets(PNG)桶 —— storage 桩或 db/storage/buckets-and-policies.sql 没装进来';
    END IF;

    -- ══════════ P · 码 ══════════
    IF NOT EXISTS (SELECT 1 FROM permissions WHERE code = 'action.manage_signatories' AND category = 'action'
                    AND requires_view_any = ARRAY['action.manage_signatories', 'module.suppliers.view']) THEN
        RAISE EXCEPTION 'FIXTURE 306P 失败:action.manage_signatories 不在目录里或没声明查看码'; END IF;
    IF (SELECT string_agg(r.code, ',' ORDER BY r.code) FROM role_permissions rp JOIN roles r ON r.id = rp.role_id
         WHERE rp.permission_code = 'action.manage_signatories') IS DISTINCT FROM 'admin' THEN
        RAISE EXCEPTION 'FIXTURE 306P 失败:引导应当只把 action.manage_signatories 授给 admin(Q3)'; END IF;

    -- ── 布景 ──
    INSERT INTO auth.users (id) VALUES (u_admin), (u_cco), (u_sig), (u_sig2), (u_other), (u_wh), (u_cv), (u_term_nobuy);
    INSERT INTO user_roles (user_id, role_id) VALUES
        (u_admin, pg_temp.f306_role('fx306-admin', ARRAY(SELECT code FROM permissions))),
        (u_cco, pg_temp.f306_role('fx306-cco', all_read || 'action.contract_terms'::text)),
        (u_sig, pg_temp.f306_role('fx306-sig', all_read)),
        (u_sig2, pg_temp.f306_role('fx306-sig2', all_read)),
        (u_other, pg_temp.f306_role('fx306-other', all_read)),
        (u_wh, pg_temp.f306_role('fx306-wh', ARRAY['module.suppliers.view'])),
        (u_cv, pg_temp.f306_role('fx306-cv', ARRAY['module.customers.view'])),
        (u_term_nobuy, pg_temp.f306_role('fx306-tnb', ARRAY['module.suppliers.view', 'action.contract_terms']));
    INSERT INTO employees (code, legal_name, employment_type, work_category, hire_date, user_id)
    VALUES ('ZZ-F306-S', '签署人 甲', 'full_time', 'office', CURRENT_DATE - 400, u_sig) RETURNING id INTO e_sig;
    INSERT INTO employees (code, legal_name, employment_type, work_category, hire_date, user_id)
    VALUES ('ZZ-F306-S2', 'fixture 306 signer two', 'full_time', 'office', CURRENT_DATE - 400, u_sig2) RETURNING id INTO e_sig2;
    INSERT INTO employees (code, legal_name, employment_type, work_category, hire_date, user_id)
    VALUES ('ZZ-F306-O', 'fixture 306 other', 'full_time', 'office', CURRENT_DATE - 400, u_other) RETURNING id INTO e_other;
    INSERT INTO employees (code, legal_name, employment_type, work_category, hire_date)
    VALUES ('ZZ-F306-N', 'fixture 306 no login', 'full_time', 'office', CURRENT_DATE - 400) RETURNING id INTO e_nologin;
    INSERT INTO customers (code, legal_name, country, payment_terms_days) VALUES ('ZZ306-C1', 'Fixture 306 Customer', 'SG', 30) RETURNING id INTO v_cust;
    INSERT INTO suppliers (status, code, legal_name, country, counterparty_type) VALUES ('active', 'ZZ306-S1', 'Fixture 306 Supplier', 'SG', 'goods_supplier') RETURNING id INTO v_sup;
    -- 属主路径建合同(fixture 304 的做法):生效中的直接写成 active —— 走 CFO 的那条路由 terms 那一族的 fixture 证
    INSERT INTO contracts (customer_id, kind, title, effective_from, status) VALUES (v_cust, 'offtake', 'F306 active', DATE '2026-01-01', 'active') RETURNING id, code INTO c_act, code_act;
    INSERT INTO contracts (customer_id, kind, title, effective_from, status) VALUES (v_cust, 'offtake', 'F306 draft', DATE '2026-01-01', 'draft') RETURNING id, code INTO c_draft, code_draft;
    INSERT INTO contracts (supplier_id, kind, title, effective_from, status) VALUES (v_sup, 'supply', 'F306 buy', DATE '2026-01-01', 'active') RETURNING id INTO c_buy;
    INSERT INTO contracts (customer_id, kind, title, effective_from, status) VALUES (v_cust, 'offtake', 'F306 suspended', DATE '2026-01-01', 'suspended') RETURNING id INTO c_susp;
    INSERT INTO contracts (customer_id, kind, title, effective_from, status) VALUES (v_cust, 'offtake', 'F306 expired', DATE '2026-01-01', 'expired') RETURNING id INTO c_exp;

    -- ══════════ L · 名单 ══════════
    v := pg_temp.f306_call(u_cco, format('SELECT contract_signatory_add(%L::uuid, ''Director'')::text', e_sig));
    IF v <> 'ERR|PERMISSION_DENIED|action.manage_signatories' THEN RAISE EXCEPTION 'FIXTURE 306L 失败:没有码的人加得了签署人 → %', v; END IF;
    v := pg_temp.f306_call(u_admin, format('SELECT contract_signatory_add(%L::uuid, ''Director'')::text', e_sig));
    IF v LIKE 'ERR|%' THEN RAISE EXCEPTION 'FIXTURE 306L 失败:admin 加不了签署人 → %', v; END IF;
    s_sig := (v::jsonb ->> 'id')::uuid;
    v := pg_temp.f306_call(u_admin, format('SELECT contract_signatory_add(%L::uuid, ''Director'')::text', e_sig));
    IF v <> 'ERR|CONTRACT_SIGNATORY_ALREADY_LISTED|ZZ-F306-S' THEN RAISE EXCEPTION 'FIXTURE 306L 失败:重复 → %', v; END IF;
    v := pg_temp.f306_call(u_admin, format('SELECT contract_signatory_add(%L::uuid, ''Director'')::text', e_nologin));
    IF v <> 'ERR|CONTRACT_SIGNATORY_NO_LOGIN|ZZ-F306-N' THEN RAISE EXCEPTION 'FIXTURE 306L 失败:没有登录账号 → %', v; END IF;
    v := pg_temp.f306_call(u_admin, format('SELECT contract_signatory_add(%L::uuid, ''  '')::text', e_sig2));
    IF v <> 'ERR|CONTRACT_SIGNATORY_TITLE_REQUIRED' THEN RAISE EXCEPTION 'FIXTURE 306L 失败:职衔空 → %', v; END IF;
    v := pg_temp.f306_call(u_admin, format('SELECT contract_signatory_add(%L::uuid, ''Finance Director'')::text', e_sig2));
    s_sig2 := (v::jsonb ->> 'id')::uuid;
    -- 加 → 移除 → 再移除 → 再加(新的一行)
    s_tmp := (pg_temp.f306_call(u_admin, format('SELECT contract_signatory_add(%L::uuid, ''Manager'')::text', e_other))::jsonb ->> 'id')::uuid;
    v := pg_temp.f306_call(u_admin, format('SELECT contract_signatory_remove(%L::uuid)::text', s_tmp));
    IF v LIKE 'ERR|%' OR (SELECT removed_at IS NULL OR removed_by IS DISTINCT FROM u_admin FROM contract_signatories WHERE id = s_tmp) THEN
        RAISE EXCEPTION 'FIXTURE 306L 失败:移除应当只记时刻与人 → %', v; END IF;
    v := pg_temp.f306_call(u_admin, format('SELECT contract_signatory_remove(%L::uuid)::text', s_tmp));
    IF v <> 'ERR|CONTRACT_SIGNATORY_NOT_LISTED' THEN RAISE EXCEPTION 'FIXTURE 306L 失败:移除两次 → %', v; END IF;
    v := pg_temp.f306_call(u_sig, format('SELECT contract_signatory_remove(%L::uuid)::text', s_sig));
    IF v <> 'ERR|PERMISSION_DENIED|action.manage_signatories' THEN RAISE EXCEPTION 'FIXTURE 306L 失败:签署人自己移除得了名单 → %', v; END IF;
    BEGIN
        UPDATE contract_signatories SET title = 'CEO' WHERE id = s_sig;
        RAISE EXCEPTION 'FIXTURE 306L 失败:守卫没挡住改职衔';
    EXCEPTION WHEN OTHERS THEN
        IF SQLERRM <> 'CONTRACT_SIGNATORY_IMMUTABLE' THEN RAISE; END IF;
    END;
    IF (SELECT count(*) FROM contract_signatories WHERE employee_id = e_other) <> 1
       OR pg_temp.f306_rc(u_other, 'SELECT count(*) FROM contract_signatories') <> 1
       OR pg_temp.f306_rc(u_cco, 'SELECT count(*) FROM contract_signatories') <> 0
       OR pg_temp.f306_rc(u_admin, 'SELECT count(*) FROM contract_signatories') <> 3 THEN
        RAISE EXCEPTION 'FIXTURE 306L 失败:读 —— 本人读自己那一行,持码的人读全部,别人 0'; END IF;
    IF (SELECT count(*) FROM change_log WHERE table_name = 'contract_signatories') < 4 THEN
        RAISE EXCEPTION 'FIXTURE 306L 失败:名单的每一次改动都应当进变更记录'; END IF;

    -- ══════════ S · 签字样本 ══════════
    IF pg_temp.f306_put(u_other, 'signing-assets', format('specimens/%s/%s.png', e_other, gen_random_uuid()), 100, 'image/png') <> -1 THEN
        RAISE EXCEPTION 'FIXTURE 306S 失败:不在名单上的人传得进样本'; END IF;
    IF pg_temp.f306_put(u_admin, 'signing-assets', format('specimens/%s/%s.png', e_sig, sp1), 100, 'image/png') <> -1 THEN
        RAISE EXCEPTION 'FIXTURE 306S 失败:admin 替别人传得进签名(Q4)'; END IF;
    IF pg_temp.f306_put(u_sig, 'signing-assets', format('specimens/%s/%s.png', e_sig2, sp1), 100, 'image/png') <> -1 THEN
        RAISE EXCEPTION 'FIXTURE 306S 失败:签署人传得进别人的样本路径'; END IF;
    IF pg_temp.f306_put(u_sig, 'signing-assets', format('specimens/%s/%s.png', e_sig, sp1), 1200, 'image/png') <> 1 THEN
        RAISE EXCEPTION 'FIXTURE 306S 失败:签署人传不进自己的样本路径'; END IF;
    v := pg_temp.f306_call(u_admin, format('SELECT signature_specimen_record(%L::uuid, %L)::text', sp1, h1));
    IF v <> 'ERR|CONTRACT_SIGN_NOT_SIGNATORY' THEN RAISE EXCEPTION 'FIXTURE 306S 失败:admin 登记得了别人的样本 → %', v; END IF;
    v := pg_temp.f306_call(u_sig, format('SELECT signature_specimen_record(%L::uuid, %L)::text', sp1, 'XYZ'));
    IF v <> 'ERR|SIGNING_ASSET_HASH_INVALID' THEN RAISE EXCEPTION 'FIXTURE 306S 失败:坏的哈希 → %', v; END IF;
    v := pg_temp.f306_call(u_sig, format('SELECT signature_specimen_record(%L::uuid, %L)::text', gen_random_uuid(), h1));
    IF v <> 'ERR|SIGNING_ASSET_NOT_STORED' THEN RAISE EXCEPTION 'FIXTURE 306S 失败:对象不在 → %', v; END IF;
    v := pg_temp.f306_call(u_sig, format('SELECT signature_specimen_record(%L::uuid, %L)::text', sp1, h1));
    IF v LIKE 'ERR|%' THEN RAISE EXCEPTION 'FIXTURE 306S 失败:签署人登记不了自己的样本 → %', v; END IF;
    PERFORM pg_temp.f306_put(u_sig, 'signing-assets', format('specimens/%s/%s.png', e_sig, sp2), 1300, 'image/png');
    v := pg_temp.f306_call(u_sig, format('SELECT signature_specimen_record(%L::uuid, %L)::text', sp2, h2));
    IF v LIKE 'ERR|%' OR (SELECT superseded_at IS NULL FROM signature_specimens WHERE id = sp1)
       OR (SELECT superseded_at IS NOT NULL OR file_size <> 1300 FROM signature_specimens WHERE id = sp2) THEN
        RAISE EXCEPTION 'FIXTURE 306S 失败:换一张样本,旧的应当记 superseded_at、新的在用 → %', v; END IF;
    BEGIN
        UPDATE signature_specimens SET sha256 = h3 WHERE id = sp2;
        RAISE EXCEPTION 'FIXTURE 306S 失败:守卫没挡住改样本的哈希';
    EXCEPTION WHEN OTHERS THEN
        IF SQLERRM <> 'SIGNING_ASSET_IMMUTABLE|signature_specimens' THEN RAISE; END IF;
    END;
    IF pg_temp.f306_rc(u_sig, format('SELECT count(*) FROM storage.objects WHERE bucket_id = ''signing-assets'' AND name LIKE ''specimens/%s/%%''', e_sig)) <> 2
       OR pg_temp.f306_rc(u_admin, format('SELECT count(*) FROM storage.objects WHERE bucket_id = ''signing-assets'' AND name LIKE ''specimens/%s/%%''', e_sig)) <> 0
       OR pg_temp.f306_rc(u_admin, 'SELECT count(*) FROM signature_specimens') <> 2
       OR pg_temp.f306_rc(u_other, 'SELECT count(*) FROM signature_specimens') <> 0 THEN
        RAISE EXCEPTION 'FIXTURE 306S 失败:样本图只有本人读得到;持码的人读得到行、读不到图;别人什么都读不到'; END IF;

    -- ══════════ U · 上传未签文件 ══════════
    v := pg_temp.f306_call(u_sig, format('SELECT contract_file_begin(%L::uuid, ''original'', ''c.pdf'', ''application/pdf'', 1000)::text', c_draft));
    IF v <> 'ERR|PERMISSION_DENIED|action.contract_terms' THEN RAISE EXCEPTION 'FIXTURE 306U 失败:不持 contract_terms 的人传得了 → %', v; END IF;
    v := pg_temp.f306_call(u_term_nobuy, format('SELECT contract_file_begin(%L::uuid, ''original'', ''c.pdf'', ''application/pdf'', 1000)::text', c_buy));
    IF v NOT LIKE 'ERR|CONTRACT_FILE_RESTRICTED|%' THEN RAISE EXCEPTION 'FIXTURE 306U 失败:读不到价格的人传得了(Q8)→ %', v; END IF;
    v := pg_temp.f306_call(u_cco, format('SELECT contract_file_begin(%L::uuid, ''signed'', ''c.pdf'', ''application/pdf'', 1000)::text', c_draft));
    IF v <> 'ERR|CONTRACT_FILE_KIND_INVALID|signed' THEN RAISE EXCEPTION 'FIXTURE 306U 失败:种类 → %', v; END IF;
    v := pg_temp.f306_call(u_cco, format('SELECT contract_file_begin(%L::uuid, ''original'', ''c.png'', ''image/png'', 1000)::text', c_draft));
    IF v <> 'ERR|CONTRACT_FILE_TYPE_NOT_ACCEPTED|image/png' THEN RAISE EXCEPTION 'FIXTURE 306U 失败:不是 PDF → %', v; END IF;
    v := pg_temp.f306_call(u_cco, format('SELECT contract_file_begin(%L::uuid, ''original'', ''c.pdf'', ''application/pdf'', 26214401)::text', c_draft));
    IF v <> 'ERR|CONTRACT_FILE_TOO_LARGE|26214400' THEN RAISE EXCEPTION 'FIXTURE 306U 失败:超过 25 MB → %', v; END IF;
    v := pg_temp.f306_call(u_cco, format('SELECT contract_file_begin(%L::uuid, ''original'', ''c.pdf'', ''application/pdf'', 0)::text', c_draft));
    IF v <> 'ERR|CONTRACT_FILE_EMPTY' THEN RAISE EXCEPTION 'FIXTURE 306U 失败:空文件 → %', v; END IF;
    v := pg_temp.f306_call(u_cco, format('SELECT contract_file_begin(%L::uuid, ''original'', ''c.pdf'', ''application/pdf'', 1000)::text', c_susp));
    IF v NOT LIKE 'ERR|CONTRACT_FILE_CONTRACT_CLOSED|%|suspended' THEN RAISE EXCEPTION 'FIXTURE 306U 失败:暂停的合同(Q1)→ %', v; END IF;
    v := pg_temp.f306_call(u_cco, format('SELECT contract_file_begin(%L::uuid, ''original'', ''c.pdf'', ''application/pdf'', 1000)::text', c_exp));
    IF v NOT LIKE 'ERR|CONTRACT_FILE_CONTRACT_CLOSED|%|expired' THEN RAISE EXCEPTION 'FIXTURE 306U 失败:到期的合同 → %', v; END IF;
    v := pg_temp.f306_call(u_cco, format('SELECT contract_file_begin(%L::uuid, ''countersigned'', ''c.pdf'', ''application/pdf'', 1000)::text', c_draft));
    IF v <> 'ERR|CONTRACT_COUNTERSIGN_NEEDS_SIGNED|' || code_draft THEN RAISE EXCEPTION 'FIXTURE 306U 失败:没签就传签回件(Q10)→ %', v; END IF;
    IF EXISTS (SELECT 1 FROM contract_files) THEN RAISE EXCEPTION 'FIXTURE 306U 失败:被拒的 begin 不该登记任何一行'; END IF;
    -- 草稿上传一份,再替换一份
    v_res := pg_temp.f306_call(u_cco, format('SELECT contract_file_begin(%L::uuid, ''original'', ''draft-v1.pdf'', ''application/pdf'', 1000)::text', c_draft))::jsonb;
    f1 := (v_res ->> 'id')::uuid; f1p := v_res ->> 'path';
    IF v_res ->> 'bucket' <> 'contract-files' OR f1p <> c_draft::text || '/' || f1::text || '.pdf' THEN
        RAISE EXCEPTION 'FIXTURE 306U 失败:路径应当是 <合同>/<文件>.pdf,实得 %', v_res; END IF;
    IF pg_temp.f306_put(u_other, 'contract-files', f1p, 1000, 'application/pdf') <> -1
       OR pg_temp.f306_put(u_cco, 'contract-files', c_draft::text || '/elsewhere.pdf', 1000, 'application/pdf') <> -1 THEN
        RAISE EXCEPTION 'FIXTURE 306U 失败:存储放行了别人 / 一条没登记过的路径'; END IF;
    IF pg_temp.f306_put(u_cco, 'contract-files', f1p, 999, 'application/pdf') <> 1 THEN
        RAISE EXCEPTION 'FIXTURE 306U 失败:登记的人传不进登记的路径'; END IF;
    v := pg_temp.f306_call(u_cco, format('SELECT contract_file_finish(%L::uuid, %L)::text', f1, h1));
    IF v <> 'ERR|CONTRACT_FILE_MISMATCH' THEN RAISE EXCEPTION 'FIXTURE 306U 失败:大小对不上 → %', v; END IF;
    UPDATE storage.objects SET metadata = jsonb_build_object('size', 1000, 'mimetype', 'application/pdf') WHERE name = f1p;
    v := pg_temp.f306_call(u_other, format('SELECT contract_file_finish(%L::uuid, %L)::text', f1, h1));
    IF v <> 'ERR|CONTRACT_FILE_NOT_FOUND' THEN RAISE EXCEPTION 'FIXTURE 306U 失败:别人 finish 得了 → %', v; END IF;
    v := pg_temp.f306_call(u_cco, format('SELECT contract_file_finish(%L::uuid, %L)::text', f1, h1));
    IF v LIKE 'ERR|%' OR (SELECT status <> 'current' OR sha256 <> h1 OR stored_at IS NULL FROM contract_files WHERE id = f1) THEN
        RAISE EXCEPTION 'FIXTURE 306U 失败:finish → %', v; END IF;
    v_res := pg_temp.f306_call(u_cco, format('SELECT contract_file_begin(%L::uuid, ''original'', ''draft-v2.pdf'', ''application/pdf'', 2000)::text', c_draft))::jsonb;
    f2 := (v_res ->> 'id')::uuid; f2p := v_res ->> 'path';
    PERFORM pg_temp.f306_put(u_cco, 'contract-files', f2p, 2000, 'application/pdf');
    v := pg_temp.f306_call(u_cco, format('SELECT contract_file_finish(%L::uuid, %L)::text', f2, h2));
    IF v LIKE 'ERR|%' OR (SELECT status FROM contract_files WHERE id = f1) <> 'superseded'
       OR (SELECT status FROM contract_files WHERE id = f2) <> 'current' THEN
        RAISE EXCEPTION 'FIXTURE 306U 失败:替换 —— 旧的应当 superseded、新的在用(A)→ %', v; END IF;
    -- 供应商合同一份(R 臂用)
    v_res := pg_temp.f306_call(u_cco, format('SELECT contract_file_begin(%L::uuid, ''original'', ''buy.pdf'', ''application/pdf'', 500)::text', c_buy))::jsonb;
    fb := (v_res ->> 'id')::uuid; fbp := v_res ->> 'path';
    PERFORM pg_temp.f306_put(u_cco, 'contract-files', fbp, 500, 'application/pdf');
    v := pg_temp.f306_call(u_cco, format('SELECT contract_file_finish(%L::uuid, %L)::text', fb, h1));
    -- 没传成:abandon
    v_res := pg_temp.f306_call(u_cco, format('SELECT contract_file_begin(%L::uuid, ''original'', ''lost.pdf'', ''application/pdf'', 10)::text', c_draft))::jsonb;
    v := pg_temp.f306_call(u_cco, format('SELECT contract_file_abandon(%L::uuid)::text', v_res ->> 'id'));
    IF v LIKE 'ERR|%' OR (SELECT status FROM contract_files WHERE id = (v_res ->> 'id')::uuid) <> 'abandoned'
       OR (SELECT status FROM contract_files WHERE id = f2) <> 'current' THEN
        RAISE EXCEPTION 'FIXTURE 306U 失败:abandon → %', v; END IF;

    -- ══════════ R · 读(Q8)══════════
    IF pg_temp.f306_rc(u_wh, format('SELECT count(*) FROM contract_files WHERE contract_id = %L', c_buy)) <> 0
       OR pg_temp.f306_rc(u_wh, format('SELECT count(*) FROM storage.objects WHERE bucket_id = ''contract-files'' AND name = %L', fbp)) <> 0
       OR pg_temp.f306_rc(u_cv, format('SELECT count(*) FROM contract_files WHERE contract_id = %L', c_draft)) <> 0
       OR pg_temp.f306_rc(u_cv, format('SELECT count(*) FROM storage.objects WHERE bucket_id = ''contract-files'' AND name = %L', f2p)) <> 0 THEN
        RAISE EXCEPTION 'FIXTURE 306R 失败:只持读码、不持那一侧价格码的人读到了合同文件(Q8)'; END IF;
    IF pg_temp.f306_rc(u_other, format('SELECT count(*) FROM contract_files WHERE contract_id = %L', c_buy)) <> 1
       OR pg_temp.f306_rc(u_other, format('SELECT count(*) FROM storage.objects WHERE bucket_id = ''contract-files'' AND name = %L', fbp)) <> 1
       OR pg_temp.f306_rc(u_other, format('SELECT count(*) FROM contract_files WHERE contract_id = %L', c_draft)) <> 2 THEN
        RAISE EXCEPTION 'FIXTURE 306R 失败:两样都持的人应当读得到(还在传、没传成的那两行不算:abandoned 只给传它的人)'; END IF;

    -- ══════════ G · 签 ══════════
    -- 生效中的合同上传一份未签文件(Q1:生效中可以传)
    v_res := pg_temp.f306_call(u_cco, format('SELECT contract_file_begin(%L::uuid, ''original'', ''Supply agreement.pdf'', ''application/pdf'', 3000)::text', c_act))::jsonb;
    f3 := (v_res ->> 'id')::uuid; f3p := v_res ->> 'path';
    PERFORM pg_temp.f306_put(u_cco, 'contract-files', f3p, 3000, 'application/pdf');
    v := pg_temp.f306_call(u_cco, format('SELECT contract_file_finish(%L::uuid, %L)::text', f3, h3));
    IF v LIKE 'ERR|%' THEN RAISE EXCEPTION 'FIXTURE 306G 失败:生效中的合同传不了未签文件(Q1)→ %', v; END IF;
    v := pg_temp.f306_call(u_sig, format('SELECT contract_sign_begin(%L::uuid, false, 1, 0.8, 0.1)::text', f2), 10);
    IF v <> 'ERR|CONTRACT_SIGN_NOT_ACTIVE|' || code_draft || '|draft' THEN RAISE EXCEPTION 'FIXTURE 306G 失败:草稿上签得了(Q1)→ %', v; END IF;
    v := pg_temp.f306_call(u_sig, format('SELECT contract_sign_begin(%L::uuid, false, 1, 0.8, 0.1)::text', f1), 10);
    IF v <> 'ERR|CONTRACT_SIGN_NOT_CURRENT_ORIGINAL|' || code_draft THEN RAISE EXCEPTION 'FIXTURE 306G 失败:被替换的那一份签得了 → %', v; END IF;
    v := pg_temp.f306_call(u_other, format('SELECT contract_sign_begin(%L::uuid, false, 1, 0.8, 0.1)::text', f3), 10);
    IF v <> 'ERR|CONTRACT_SIGN_NOT_SIGNATORY' THEN RAISE EXCEPTION 'FIXTURE 306G 失败:不在名单上的人签得了(Q3)→ %', v; END IF;
    v := pg_temp.f306_call(u_admin, format('SELECT contract_sign_begin(%L::uuid, false, 1, 0.8, 0.1)::text', f3), 10);
    IF v <> 'ERR|CONTRACT_SIGN_NOT_SIGNATORY' THEN RAISE EXCEPTION 'FIXTURE 306G 失败:持全部码、不在名单上的 admin 签得了 → %', v; END IF;
    v := pg_temp.f306_call(u_sig, format('SELECT contract_sign_begin(%L::uuid, false, 1, 0.8, 0.1)::text', f3), NULL);
    IF v <> 'ERR|CONTRACT_SIGN_PASSWORD_REQUIRED' THEN RAISE EXCEPTION 'FIXTURE 306G 失败:没有重新输入密码就签得了(Q5)→ %', v; END IF;
    v := pg_temp.f306_call(u_sig, format('SELECT contract_sign_begin(%L::uuid, false, 1, 0.8, 0.1)::text', f3), 600);
    IF v <> 'ERR|CONTRACT_SIGN_PASSWORD_REQUIRED' THEN RAISE EXCEPTION 'FIXTURE 306G 失败:十分钟以前的密码签得了(Q5)→ %', v; END IF;
    v := pg_temp.f306_call(u_sig2, format('SELECT contract_sign_begin(%L::uuid, false, 1, 0.8, 0.1)::text', f3), 10);
    IF v <> 'ERR|CONTRACT_SIGN_NO_SPECIMEN' THEN RAISE EXCEPTION 'FIXTURE 306G 失败:没有样本就签得了(Q4)→ %', v; END IF;
    v := pg_temp.f306_call(u_sig, format('SELECT contract_sign_begin(%L::uuid, true, 1, 0.8, 0.1, 1, 0.6, 0.1)::text', f3), 10);
    IF v <> 'ERR|CONTRACT_SIGN_NO_STAMP' THEN RAISE EXCEPTION 'FIXTURE 306G 失败:没有印章却盖得了 → %', v; END IF;
    v := pg_temp.f306_call(u_sig, format('SELECT contract_sign_begin(%L::uuid, false, 1, 1.5, 0.1)::text', f3), 10);
    IF v <> 'ERR|CONTRACT_SIGN_PLACEMENT_INVALID' THEN RAISE EXCEPTION 'FIXTURE 306G 失败:位置在页外 → %', v; END IF;
    v := pg_temp.f306_call(u_sig, format('SELECT contract_sign_begin(%L::uuid, false, 0, 0.5, 0.1)::text', f3), 10);
    IF v <> 'ERR|CONTRACT_SIGN_PLACEMENT_INVALID' THEN RAISE EXCEPTION 'FIXTURE 306G 失败:第 0 页 → %', v; END IF;
    -- 暂停的合同签不了:把 c_act 暂停一下再恢复(属主路径)
    UPDATE contracts SET status = 'suspended' WHERE id = c_act;
    v := pg_temp.f306_call(u_sig, format('SELECT contract_sign_begin(%L::uuid, false, 1, 0.8, 0.1)::text', f3), 10);
    IF v <> 'ERR|CONTRACT_SIGN_NOT_ACTIVE|' || code_act || '|suspended' THEN RAISE EXCEPTION 'FIXTURE 306G 失败:暂停的合同签得了(Q1)→ %', v; END IF;
    UPDATE contracts SET status = 'active' WHERE id = c_act;

    -- ══════════ T · 公司印章 ══════════
    IF pg_temp.f306_put(u_sig, 'signing-assets', format('stamps/%s.png', st1), 900, 'image/png') <> -1 THEN
        RAISE EXCEPTION 'FIXTURE 306T 失败:签署人传得进印章'; END IF;
    IF pg_temp.f306_put(u_admin, 'signing-assets', format('stamps/%s.png', st1), 900, 'image/png') <> 1 THEN
        RAISE EXCEPTION 'FIXTURE 306T 失败:持码的人传不进印章'; END IF;
    v := pg_temp.f306_call(u_sig, format('SELECT company_stamp_record(%L::uuid, %L)::text', st1, h1));
    IF v <> 'ERR|PERMISSION_DENIED|action.manage_signatories' THEN RAISE EXCEPTION 'FIXTURE 306T 失败:签署人登记得了印章 → %', v; END IF;
    v := pg_temp.f306_call(u_admin, format('SELECT company_stamp_record(%L::uuid, %L)::text', st1, h1));
    IF v LIKE 'ERR|%' THEN RAISE EXCEPTION 'FIXTURE 306T 失败:admin 登记不了印章 → %', v; END IF;
    PERFORM pg_temp.f306_put(u_admin, 'signing-assets', format('stamps/%s.png', st2), 950, 'image/png');
    v := pg_temp.f306_call(u_admin, format('SELECT company_stamp_record(%L::uuid, %L)::text', st2, h2));
    IF v LIKE 'ERR|%' OR (SELECT superseded_at IS NULL FROM company_stamps WHERE id = st1)
       OR (SELECT superseded_at IS NOT NULL FROM company_stamps WHERE id = st2) THEN
        RAISE EXCEPTION 'FIXTURE 306T 失败:换一张印章,旧的应当记 superseded_at → %', v; END IF;
    IF pg_temp.f306_rc(u_sig, 'SELECT count(*) FROM company_stamps') <> 2
       OR pg_temp.f306_rc(u_other, 'SELECT count(*) FROM company_stamps') <> 0
       OR pg_temp.f306_rc(u_sig, format('SELECT count(*) FROM storage.objects WHERE bucket_id = ''signing-assets'' AND name = %L', format('stamps/%s.png', st2))) <> 1
       OR pg_temp.f306_rc(u_other, format('SELECT count(*) FROM storage.objects WHERE bucket_id = ''signing-assets'' AND name = %L', format('stamps/%s.png', st2))) <> 0 THEN
        RAISE EXCEPTION 'FIXTURE 306T 失败:印章 —— 签署人读得到,不在名单上的人读不到'; END IF;

    -- ── G 续:签成 ──
    v := pg_temp.f306_call(u_sig, format('SELECT contract_sign_begin(%L::uuid, true, 2, 0.8, 0.1, 2, 0.55, 0.12)::text', f3), 10);
    IF v LIKE 'ERR|%' THEN RAISE EXCEPTION 'FIXTURE 306G 失败:签署人在生效中的合同上签不了 → %', v; END IF;
    v_res := v::jsonb; sg1 := (v_res ->> 'id')::uuid; sg1p := v_res ->> 'path';
    IF v_res ->> 'source_path' <> f3p OR v_res ->> 'source_sha256' <> h3 OR v_res ->> 'signer_name' <> '签署人 甲' OR v_res ->> 'signer_title' <> 'Director'
       OR v_res ->> 'specimen_path' <> format('specimens/%s/%s.png', e_sig, sp2) OR v_res ->> 'stamp_path' <> format('stamps/%s.png', st2) THEN
        RAISE EXCEPTION 'FIXTURE 306G 失败:begin 回的源文件 / 签署人 / 在用样本 / 在用印章不对 → %', v_res; END IF;
    IF (SELECT kind <> 'signed' OR source_file_id <> f3 OR signatory_id <> s_sig OR specimen_id <> sp2 OR stamp_id <> st2
              OR signature_page <> 2 OR stamp_x <> 0.55 OR password_verified_at < now() - interval '1 minute'
              FROM contract_files WHERE id = sg1) THEN
        RAISE EXCEPTION 'FIXTURE 306G 失败:签过的那一行没记下签署人 / 样本 / 印章 / 位置 / 密码时刻'; END IF;
    IF pg_temp.f306_put(u_sig, 'contract-files', sg1p, 4321, 'application/pdf') <> 1 THEN
        RAISE EXCEPTION 'FIXTURE 306G 失败:签署人传不进签过版本的路径'; END IF;
    v := pg_temp.f306_call(u_sig, format('SELECT contract_file_finish(%L::uuid, %L)::text', sg1, h2));
    IF v LIKE 'ERR|%' OR (SELECT status <> 'current' OR file_size <> 4321 OR sha256 <> h2 FROM contract_files WHERE id = sg1) THEN
        RAISE EXCEPTION 'FIXTURE 306G 失败:签过版本存不下 → %', v; END IF;
    v := pg_temp.f306_call(u_sig2, format('SELECT contract_sign_begin(%L::uuid, false, 1, 0.8, 0.1)::text', f3), 10);
    IF v NOT IN ('ERR|CONTRACT_FILE_ALREADY_SIGNED|' || code_act, 'ERR|CONTRACT_SIGN_NO_SPECIMEN') THEN
        RAISE EXCEPTION 'FIXTURE 306G 失败:第二个签署人 → %', v; END IF;
    v := pg_temp.f306_call(u_sig, format('SELECT contract_sign_begin(%L::uuid, false, 1, 0.8, 0.1)::text', f3), 10);
    IF v <> 'ERR|CONTRACT_FILE_ALREADY_SIGNED|' || code_act THEN RAISE EXCEPTION 'FIXTURE 306G 失败:同一份签了两次(Q9)→ %', v; END IF;
    v := pg_temp.f306_call(u_cco, format('SELECT contract_file_begin(%L::uuid, ''original'', ''x.pdf'', ''application/pdf'', 10)::text', c_act));
    IF v <> 'ERR|CONTRACT_FILE_SIGNED_LOCKED|' || code_act THEN RAISE EXCEPTION 'FIXTURE 306G 失败:签过之后还能替换原件(D)→ %', v; END IF;

    -- ══════════ I · 守卫 ══════════
    BEGIN
        UPDATE contract_files SET sha256 = h1 WHERE id = sg1;
        RAISE EXCEPTION 'FIXTURE 306I 失败:守卫没挡住改哈希';
    EXCEPTION WHEN OTHERS THEN
        IF SQLERRM <> 'CONTRACT_FILE_IMMUTABLE|' || sg1 THEN RAISE; END IF;
    END;
    BEGIN
        UPDATE contract_files SET signer_name = 'someone else' WHERE id = sg1;
        RAISE EXCEPTION 'FIXTURE 306I 失败:守卫没挡住改签署人的名字';
    EXCEPTION WHEN OTHERS THEN
        IF SQLERRM <> 'CONTRACT_FILE_IMMUTABLE|' || sg1 THEN RAISE; END IF;
    END;
    BEGIN
        DELETE FROM contract_files WHERE id = sg1;
        RAISE EXCEPTION 'FIXTURE 306I 失败:守卫没挡住删一份签过的版本';
    EXCEPTION WHEN OTHERS THEN
        IF SQLERRM <> 'CONTRACT_FILE_NO_DELETE|' || sg1 THEN RAISE; END IF;
    END;
    BEGIN
        UPDATE contract_files SET status = 'void', voided_at = now(), voided_by = u_sig WHERE id = sg1;
        RAISE EXCEPTION 'FIXTURE 306I 失败:没有理由的作废没被挡住';
    EXCEPTION WHEN check_violation THEN NULL;
    END;
    IF pg_temp.f306_rc(u_sig, format('UPDATE contract_files SET file_name = ''x'' WHERE id = %L', sg1)) <> -1
       OR pg_temp.f306_rc(u_cco, format('DELETE FROM contract_files WHERE id = %L', f2)) <> -1 THEN
        RAISE EXCEPTION 'FIXTURE 306I 失败:authenticated 能直接改 / 删合同文件'; END IF;

    -- ══════════ C · 对方签回件 ══════════
    v := pg_temp.f306_call(u_sig, format('SELECT contract_file_begin(%L::uuid, ''countersigned'', ''back.pdf'', ''application/pdf'', 800)::text', c_act));
    IF v <> 'ERR|PERMISSION_DENIED|action.contract_terms' THEN RAISE EXCEPTION 'FIXTURE 306C 失败:不持 contract_terms 的人传得了签回件(Q10)→ %', v; END IF;
    UPDATE contracts SET signed_on = NULL WHERE id = c_act AND signed_on IS NOT NULL;
    v_res := pg_temp.f306_call(u_cco, format('SELECT contract_file_begin(%L::uuid, ''countersigned'', ''back.pdf'', ''application/pdf'', 800)::text', c_act))::jsonb;
    cs1 := (v_res ->> 'id')::uuid; cs1p := v_res ->> 'path';
    IF (SELECT source_file_id FROM contract_files WHERE id = cs1) <> sg1 THEN RAISE EXCEPTION 'FIXTURE 306C 失败:签回件应当挂在那一份签过版本上'; END IF;
    PERFORM pg_temp.f306_put(u_cco, 'contract-files', cs1p, 800, 'application/pdf');
    v := pg_temp.f306_call(u_cco, format('SELECT contract_file_finish(%L::uuid, %L)::text', cs1, h1));
    IF v LIKE 'ERR|%' OR (SELECT signed_on IS DISTINCT FROM (now() AT TIME ZONE 'Asia/Singapore')::date FROM contracts WHERE id = c_act) THEN
        RAISE EXCEPTION 'FIXTURE 306C 失败:签回件存下的那一天 signed_on 应当填上(Q2)→ %', v; END IF;
    v := pg_temp.f306_call(u_cco, format('SELECT contract_file_begin(%L::uuid, ''countersigned'', ''again.pdf'', ''application/pdf'', 800)::text', c_act));
    IF v <> 'ERR|CONTRACT_FILE_COUNTERSIGNED_FINAL|' || code_act THEN RAISE EXCEPTION 'FIXTURE 306C 失败:签回件之后还能再传一份 → %', v; END IF;

    -- ══════════ V · 作废 ══════════
    v := pg_temp.f306_call(u_other, format('SELECT contract_file_void(%L::uuid, ''wrong page'')::text', sg1));
    IF v <> 'ERR|CONTRACT_VOID_NOT_PERMITTED' THEN RAISE EXCEPTION 'FIXTURE 306V 失败:不在名单上、不持码的人作废得了 → %', v; END IF;
    v := pg_temp.f306_call(u_sig, format('SELECT contract_file_void(%L::uuid, ''  '')::text', sg1));
    IF v <> 'ERR|CONTRACT_VOID_REASON_REQUIRED|' || code_act THEN RAISE EXCEPTION 'FIXTURE 306V 失败:理由空 → %', v; END IF;
    v := pg_temp.f306_call(u_sig, format('SELECT contract_file_void(%L::uuid, %L)::text', f3, 'x'));
    IF v NOT LIKE 'ERR|CONTRACT_FILE_NOT_VOIDABLE|%|original|current' THEN RAISE EXCEPTION 'FIXTURE 306V 失败:作废得了一份未签原件 → %', v; END IF;
    v := pg_temp.f306_call(u_sig, format('SELECT contract_file_void(%L::uuid, ''Signed on the wrong page'')::text', sg1));
    IF v LIKE 'ERR|%' OR (v::jsonb ->> 'countersigned_voided')::int <> 1
       OR (SELECT status <> 'void' OR void_reason <> 'Signed on the wrong page' OR voided_by <> u_sig FROM contract_files WHERE id = sg1)
       OR (SELECT status FROM contract_files WHERE id = cs1) <> 'void' THEN
        RAISE EXCEPTION 'FIXTURE 306V 失败:作废签过版本,签回件应当一起作废 → %', v; END IF;
    IF pg_temp.f306_rc(u_other, format('SELECT count(*) FROM storage.objects WHERE bucket_id = ''contract-files'' AND name = %L', sg1p)) <> 1
       OR pg_temp.f306_rc(u_other, format('SELECT count(*) FROM contract_files WHERE id = %L AND status = ''void''', sg1)) <> 1 THEN
        RAISE EXCEPTION 'FIXTURE 306V 失败:作废的 PDF 应当照样读得到、列得出来(Q7)'; END IF;
    -- 作废之后:能重新签(签署人二补一张样本)
    PERFORM pg_temp.f306_put(u_sig2, 'signing-assets', format('specimens/%s/%s.png', e_sig2, sp3), 700, 'image/png');
    PERFORM pg_temp.f306_call(u_sig2, format('SELECT signature_specimen_record(%L::uuid, %L)::text', sp3, h1));
    v := pg_temp.f306_call(u_sig2, format('SELECT contract_sign_begin(%L::uuid, false, 1, 0.7, 0.2)::text', f3), 30);
    IF v LIKE 'ERR|%' THEN RAISE EXCEPTION 'FIXTURE 306V 失败:作废之后签不了 → %', v; END IF;
    sg2 := (v::jsonb ->> 'id')::uuid; sg2p := v::jsonb ->> 'path';
    PERFORM pg_temp.f306_put(u_sig2, 'contract-files', sg2p, 5000, 'application/pdf');
    v := pg_temp.f306_call(u_sig2, format('SELECT contract_file_finish(%L::uuid, %L)::text', sg2, h3));
    IF v LIKE 'ERR|%' OR (SELECT stamp_id IS NOT NULL OR signatory_id <> s_sig2 FROM contract_files WHERE id = sg2) THEN
        RAISE EXCEPTION 'FIXTURE 306V 失败:重新签 → %', v; END IF;
    -- 移除签署人不作废他签过的(Q7)
    PERFORM pg_temp.f306_call(u_admin, format('SELECT contract_signatory_remove(%L::uuid)::text', s_sig2));
    IF (SELECT status FROM contract_files WHERE id = sg2) <> 'current' THEN
        RAISE EXCEPTION 'FIXTURE 306V 失败:移除签署人把他签过的那一份作废了(Q7)'; END IF;
    v := pg_temp.f306_call(u_sig2, format('SELECT contract_file_void(%L::uuid, ''r'')::text', sg2));
    IF v <> 'ERR|CONTRACT_VOID_NOT_PERMITTED' THEN RAISE EXCEPTION 'FIXTURE 306V 失败:移出名单的人作废得了 → %', v; END IF;
    -- admin(持码、不在名单上)作废得了;之后原件能替换
    v := pg_temp.f306_call(u_admin, format('SELECT contract_file_void(%L::uuid, ''Superseded by a new draft'')::text', sg2));
    IF v LIKE 'ERR|%' THEN RAISE EXCEPTION 'FIXTURE 306V 失败:admin 作废不了(Q7)→ %', v; END IF;
    v := pg_temp.f306_call(u_cco, format('SELECT contract_file_begin(%L::uuid, ''original'', ''v3.pdf'', ''application/pdf'', 10)::text', c_act));
    IF v LIKE 'ERR|%' THEN RAISE EXCEPTION 'FIXTURE 306V 失败:作废之后替换不了原件 → %', v; END IF;

    -- ══════════ X · 删 ══════════
    DELETE FROM contracts WHERE id = c_act;
    IF EXISTS (SELECT 1 FROM contract_files WHERE contract_id = c_act) THEN
        RAISE EXCEPTION 'FIXTURE 306X 失败:合同删掉之后它的文件还在'; END IF;
    IF (SELECT count(*) FROM change_log WHERE table_name = 'contract_files') < 10
       OR (SELECT count(*) FROM change_log WHERE table_name = 'signature_specimens') < 2
       OR (SELECT count(*) FROM change_log WHERE table_name = 'company_stamps') < 2 THEN
        RAISE EXCEPTION 'FIXTURE 306X 失败:文件、样本与印章的每一次改动都应当进变更记录'; END IF;

    RAISE NOTICE 'FIXTURE 306 全部通过: P · L · S · U · R · G · T · I · C · V · X';
END;
$f306$;

ROLLBACK;

-- db/fixtures/196-a-stranger-with-a-token-sees-one-certificate-and-nothing-else.sql
-- COD-2:核验页。十条臂,而它们钉的是同一句话的两半 ——
--   **拿着令牌的人看得见【那一张证书】,而拿着令牌的人看不见【别的任何东西】。**
--
-- 【为什么每一臂都真的切成 anon 跑】本刀的全部保证都落在"匿名请求够得着什么"
-- 上,而那是一个【角色】的问题,不是一个代码路径的问题。以 postgres 跑一遍
-- 函数只能证明函数算得对,证明不了它对互联网关着门。
--
-- 臂:
--   A 有效令牌 → 渲染得出那一页(而且【每一格都对得上快照】)
--   B 匿名【够不着别的任何东西】:所有关系零行、所有函数零个,除了那一支
--   C 作废 + 有替代品 → 解析得到,并说出替代证书的【号】
--   D 作废 + 没有替代品(冲销)→ 解析得到,并说"没有替代品"
--   E 不认识的令牌与格式不对的令牌 → 【逐字节相同】的答案
--   F 两张视图对 anon 关着,而【基表里是有行的】—— 空表上的测试什么都不证明
--   G 执照的六句拒绝,每一句在它自己的条件上响
--   H 续期:两行执照,【旧的那一行】管旧的那一票货
--   I 剥离:出处、内部 uuid、令牌回声、签发人、公司电话/邮箱/网址,一个都不许在
--   J 限流:30 次失败之后限流,而【有效令牌照样解析得到】
BEGIN;
DO $fixture$
DECLARE
    r jsonb := '{}'::jsonb;
    v_issuer uuid := gen_random_uuid();
    v_role   uuid;
    mat uuid; sup uuid; cus uuid; emp uuid; emp_user uuid := gen_random_uuid();
    b_old uuid; b_new uuid; b_void uuid; b_rev uuid;
    run_id uuid;
    cod_old uuid; cod_new uuid; cod_void uuid; cod_rev uuid; cod_repl uuid;
    tok_old uuid; tok_new uuid; tok_void uuid; tok_rev uuid;
    lic_a uuid; lic_b uuid;
    v_res jsonb; v_res2 jsonb; v_err text; v_snap jsonb;
    v_n integer; v_univ integer; v_rows bigint; v_leak text; v_fns text;
    v_chase uuid;
    d_old date := CURRENT_DATE - 200;   -- 旧那一票货的加工完成日
    d_new date := CURRENT_DATE - 5;     -- 新那一票货的加工完成日
BEGIN
    -- ══════════════════════════════════════════════════════════════════════
    -- 0 · 自带数据(重建库里一行业务数据都没有 —— README 第 2 条)
    -- ══════════════════════════════════════════════════════════════════════
    INSERT INTO roles (code, name_en, name_zh, is_active)
    VALUES ('fixture-196', 'fixture', 'fixture', true) RETURNING id INTO v_role;
    INSERT INTO role_permissions (role_id, permission_code) SELECT v_role, code FROM permissions;
    INSERT INTO user_roles (user_id, role_id) VALUES (v_issuer, v_role);

    -- 公司抬头:【有行】与【法定名称填了】是两件事(fixture 195 为此红过一次)
    IF NOT EXISTS (SELECT 1 FROM company_profile) THEN
        INSERT INTO company_profile (legal_name, registration_no, address_lines, city,
                                     postal_code, country, phone, email, website)
        VALUES ('fixture 196 Pte. Ltd.', 'F196-UEN', '1 Fixture Road', 'Singapore',
                '000001', 'SG', '+65 0000 0000', 'f196@example.test', 'https://example.test');
    ELSE
        UPDATE company_profile SET
            legal_name = COALESCE(NULLIF(btrim(legal_name), ''), 'fixture 196 Pte. Ltd.'),
            registration_no = COALESCE(registration_no, 'F196-UEN'),
            phone = COALESCE(phone, '+65 0000 0000'),
            email = COALESCE(email, 'f196@example.test'),
            website = COALESCE(website, 'https://example.test');
    END IF;

    INSERT INTO materials (code, name, kind_code, may_be_processed, form_code, source_code)
    VALUES ('F196-MAT', 'fixture 196 material', 'battery_material', true, 'black_mass', 'end_of_life')
    RETURNING id INTO mat;
    INSERT INTO suppliers (code, legal_name, country, counterparty_type)
    VALUES ('F196-SUP', 'fixture 196 supplier', 'SG', 'goods_supplier') RETURNING id INTO sup;

    -- 四票货,各有各的差事
    INSERT INTO inbound_batches (code, material_id, supplier_id, quantity, unit, remaining_qty,
                                 arrival_date, source_reason_code, source_reason_note)
    VALUES ('F196-OLD',  mat, sup, 100, 'kg', 100, d_old - 10, 'other', 'fixture 196'),
           ('F196-NEW',  mat, sup, 100, 'kg', 100, d_new - 10, 'other', 'fixture 196'),
           ('F196-VOID', mat, sup, 100, 'kg', 100, d_new - 10, 'other', 'fixture 196'),
           ('F196-REV',  mat, sup, 100, 'kg', 100, d_new - 10, 'other', 'fixture 196');
    SELECT id INTO b_old  FROM inbound_batches WHERE code = 'F196-OLD';
    SELECT id INTO b_new  FROM inbound_batches WHERE code = 'F196-NEW';
    SELECT id INTO b_void FROM inbound_batches WHERE code = 'F196-VOID';
    SELECT id INTO b_rev  FROM inbound_batches WHERE code = 'F196-REV';
    -- discharged_verified 是 manual_disassembly 受理的那一个(与 fixture 195 同)
    INSERT INTO inbound_batch_safety_states (inbound_batch_id, safety_state_code)
    SELECT id, 'discharged_verified' FROM inbound_batches WHERE code LIKE 'F196-%';

    -- 把四票货各加工空(裸 INSERT —— 这里要的是【精确的台账形状】,
    -- 不是走一遍加工的全部闸门;fixture 195 的 I 臂走真路径)
    FOR v_n IN 1..4 LOOP
        INSERT INTO processing_runs (process_date, total_input, total_output, loss_qty, status,
                                     allocation_basis, operation_type_code, created_by)
        VALUES (CASE v_n WHEN 1 THEN d_old ELSE d_new END, 100, 80, 20, 'committed',
                'weight', 'manual_disassembly', v_issuer)
        RETURNING id INTO run_id;
        INSERT INTO processing_inputs (run_id, inbound_batch_id, quantity_consumed)
        VALUES (run_id, CASE v_n WHEN 1 THEN b_old WHEN 2 THEN b_new
                                 WHEN 3 THEN b_void ELSE b_rev END, 100);
        INSERT INTO inventory_movements (inbound_batch_id, movement_type, qty_delta, run_id,
                                         business_date, created_by)
        VALUES (CASE v_n WHEN 1 THEN b_old WHEN 2 THEN b_new
                         WHEN 3 THEN b_void ELSE b_rev END,
                'processing_consume', -100, run_id,
                CASE v_n WHEN 1 THEN d_old ELSE d_new END, v_issuer);
    END LOOP;
    UPDATE inbound_batches SET remaining_qty = 0
     WHERE id IN (b_old, b_new, b_void, b_rev);

    PERFORM refresh_cod_for_batch(b_old);
    PERFORM refresh_cod_for_batch(b_new);
    PERFORM refresh_cod_for_batch(b_void);
    PERFORM refresh_cod_for_batch(b_rev);
    SELECT id INTO cod_old  FROM certificates_of_destruction WHERE inbound_batch_id = b_old;
    SELECT id INTO cod_new  FROM certificates_of_destruction WHERE inbound_batch_id = b_new;
    SELECT id INTO cod_void FROM certificates_of_destruction WHERE inbound_batch_id = b_void;
    SELECT id INTO cod_rev  FROM certificates_of_destruction WHERE inbound_batch_id = b_rev;
    IF cod_old IS NULL OR cod_new IS NULL OR cod_void IS NULL OR cod_rev IS NULL THEN
        RAISE EXCEPTION 'F196 前提不成立:四张证书没有全部成立';
    END IF;

    -- ══════════════════════════════════════════════════════════════════════
    -- G · 执照的【六句】拒绝,每一句在它自己的条件上响
    -- ══════════════════════════════════════════════════════════════════════
    -- 【为什么这一臂排在最前】它要在【还没有任何执照行】的状态下起手,
    -- 而后面每一臂都需要一张签得出来的证书。顺序本身是前提。
    EXECUTE 'SET LOCAL ROLE authenticated';
    PERFORM set_config('request.jwt.claims', format('{"sub":"%s","role":"authenticated"}', v_issuer), true);

    -- G1 · 一行都没有 → 去哪儿录
    v_err := NULL;
    BEGIN PERFORM issue_cod(cod_new); EXCEPTION WHEN OTHERS THEN v_err := SQLERRM; END;
    IF v_err NOT LIKE 'COD_LICENCE_NOT_RECORDED|/purchasing/licences%' THEN
        RAISE EXCEPTION 'G1 失败:措辞是 "%"', v_err;
    END IF;

    -- G2 · active,但有效期缺一端 —— 【NULL 不是"长期有效",是没有人录过】
    RESET ROLE;
    INSERT INTO company_compliance (cert_type_code, cert_no, issuing_body, status, valid_from, valid_until)
    VALUES ('gwdf', 'F196-NULLEND', 'NEA', 'active', d_new - 100, NULL) RETURNING id INTO lic_a;
    EXECUTE 'SET LOCAL ROLE authenticated';
    PERFORM set_config('request.jwt.claims', format('{"sub":"%s","role":"authenticated"}', v_issuer), true);
    v_err := NULL;
    BEGIN PERFORM issue_cod(cod_new); EXCEPTION WHEN OTHERS THEN v_err := SQLERRM; END;
    IF v_err NOT LIKE 'COD_LICENCE_DATES_NOT_RECORDED|F196-NULLEND%' THEN
        RAISE EXCEPTION 'G2 失败:有效期缺一端却没有按名拒 —— 措辞是 "%"', v_err;
    END IF;

    -- G3 · 有一行盖住了这一天,但它不是 active
    RESET ROLE;
    UPDATE company_compliance SET valid_until = d_new + 100, status = 'revoked' WHERE id = lic_a;
    EXECUTE 'SET LOCAL ROLE authenticated';
    PERFORM set_config('request.jwt.claims', format('{"sub":"%s","role":"authenticated"}', v_issuer), true);
    v_err := NULL;
    BEGIN PERFORM issue_cod(cod_new); EXCEPTION WHEN OTHERS THEN v_err := SQLERRM; END;
    IF v_err NOT LIKE 'COD_LICENCE_NOT_ACTIVE|F196-NULLEND|revoked%' THEN
        RAISE EXCEPTION 'G3 失败:措辞是 "%"', v_err;
    END IF;

    -- G4 · 过期了 —— 真正会发生的那一种,两个日期都点名
    RESET ROLE;
    UPDATE company_compliance SET status = 'active',
           valid_from = d_new - 300, valid_until = d_new - 1 WHERE id = lic_a;
    EXECUTE 'SET LOCAL ROLE authenticated';
    PERFORM set_config('request.jwt.claims', format('{"sub":"%s","role":"authenticated"}', v_issuer), true);
    v_err := NULL;
    BEGIN PERFORM issue_cod(cod_new); EXCEPTION WHEN OTHERS THEN v_err := SQLERRM; END;
    IF v_err NOT LIKE format('COD_LICENCE_EXPIRED|%s|%s|F196-NULLEND%%', d_new, d_new - 1) THEN
        RAISE EXCEPTION 'G4 失败:措辞是 "%"', v_err;
    END IF;

    -- G5 · 还没生效 —— 措辞必须是【数据对不上】,不是业务规则
    RESET ROLE;
    UPDATE company_compliance SET valid_from = d_new + 1, valid_until = d_new + 300 WHERE id = lic_a;
    EXECUTE 'SET LOCAL ROLE authenticated';
    PERFORM set_config('request.jwt.claims', format('{"sub":"%s","role":"authenticated"}', v_issuer), true);
    v_err := NULL;
    BEGIN PERFORM issue_cod(cod_new); EXCEPTION WHEN OTHERS THEN v_err := SQLERRM; END;
    IF v_err NOT LIKE format('COD_LICENCE_NOT_YET_IN_FORCE|%s|%s|F196-NULLEND%%', d_new, d_new + 1) THEN
        RAISE EXCEPTION 'G5 失败:措辞是 "%"', v_err;
    END IF;

    -- G6 · 两行都盖住了这一天 → 有一行录错了,而系统【不替你挑】
    RESET ROLE;
    UPDATE company_compliance SET valid_from = d_new - 50, valid_until = d_new + 50 WHERE id = lic_a;
    INSERT INTO company_compliance (cert_type_code, cert_no, issuing_body, status, valid_from, valid_until)
    VALUES ('gwdf', 'F196-DUP', 'NEA', 'active', d_new - 60, d_new + 60) RETURNING id INTO lic_b;
    EXECUTE 'SET LOCAL ROLE authenticated';
    PERFORM set_config('request.jwt.claims', format('{"sub":"%s","role":"authenticated"}', v_issuer), true);
    v_err := NULL;
    BEGIN PERFORM issue_cod(cod_new); EXCEPTION WHEN OTHERS THEN v_err := SQLERRM; END;
    IF v_err NOT LIKE 'COD_LICENCE_PERIODS_OVERLAP%' THEN
        RAISE EXCEPTION 'G6 失败:两张都在效却没有按名拒 —— 措辞是 "%"', v_err;
    END IF;
    IF v_err NOT LIKE '%F196-NULLEND%' OR v_err NOT LIKE '%F196-DUP%' THEN
        RAISE EXCEPTION 'G6b 失败:重叠的拒绝没有【把两张都点名】—— "%"', v_err;
    END IF;
    r := r || jsonb_build_object('G_six_named_refusals', true);

    -- ══════════════════════════════════════════════════════════════════════
    -- H · 续期:两行执照,【旧的那一行】管旧的那一票货
    -- ══════════════════════════════════════════════════════════════════════
    -- 【这一臂是整条规则的意义所在】一次续期不该回头把旧的那几票货重新盖上
    -- 新的执照号 —— 那等于替一份已经发出去的法律文件改写它当时的依据。
    RESET ROLE;
    UPDATE company_compliance SET cert_no = 'F196-LIC-OLD',
           valid_from = d_old - 30, valid_until = d_old + 30 WHERE id = lic_a;
    UPDATE company_compliance SET cert_no = 'F196-LIC-NEW',
           valid_from = d_new - 30, valid_until = d_new + 30 WHERE id = lic_b;

    EXECUTE 'SET LOCAL ROLE authenticated';
    PERFORM set_config('request.jwt.claims', format('{"sub":"%s","role":"authenticated"}', v_issuer), true);
    PERFORM issue_cod(cod_old);
    PERFORM issue_cod(cod_new);
    PERFORM issue_cod(cod_void);
    PERFORM issue_cod(cod_rev);
    RESET ROLE;

    SELECT snapshot INTO v_snap FROM certificates_of_destruction WHERE id = cod_old;
    IF v_snap->'licence'->>'cert_no' <> 'F196-LIC-OLD' THEN
        RAISE EXCEPTION 'H1 失败:旧的那一票货盖上了 "%" —— 续期回头改写了历史',
            v_snap->'licence'->>'cert_no';
    END IF;
    SELECT snapshot INTO v_snap FROM certificates_of_destruction WHERE id = cod_new;
    IF v_snap->'licence'->>'cert_no' <> 'F196-LIC-NEW' THEN
        RAISE EXCEPTION 'H2 失败:新的那一票货盖上了 "%"', v_snap->'licence'->>'cert_no';
    END IF;
    r := r || jsonb_build_object('H_renewal_does_not_restamp_history', true);

    SELECT verification_token INTO tok_old  FROM certificates_of_destruction WHERE id = cod_old;
    SELECT verification_token INTO tok_new  FROM certificates_of_destruction WHERE id = cod_new;
    SELECT verification_token INTO tok_void FROM certificates_of_destruction WHERE id = cod_void;
    SELECT verification_token INTO tok_rev  FROM certificates_of_destruction WHERE id = cod_rev;

    -- ══════════════════════════════════════════════════════════════════════
    -- A + I · 有效令牌渲染得出那一页,而【剥掉的东西一个都不在】
    -- ══════════════════════════════════════════════════════════════════════
    -- ★ 从这里起,凡是"匿名"的臂,都真的切成 anon 跑 ★
    EXECUTE 'SET LOCAL ROLE anon';
    PERFORM set_config('request.jwt.claims', '', true);
    v_res := cod_verification(tok_new::text);
    RESET ROLE;

    IF v_res->>'result' <> 'ok' THEN RAISE EXCEPTION 'A1 失败:有效令牌没有解析出来:%', v_res; END IF;
    IF v_res->>'status' <> 'issued' THEN RAISE EXCEPTION 'A2 失败:状态是 "%"', v_res->>'status'; END IF;
    IF v_res->'certificate'->>'code' !~ '^COD-[0-9]{4}-[0-9]{4}$' THEN
        RAISE EXCEPTION 'A3 失败:页上的证书号是 "%"', v_res->'certificate'->>'code';
    END IF;
    -- 【每一格都对得上快照】—— 页面不是另算一遍,它读的就是冻住的那一行
    SELECT snapshot INTO v_snap FROM certificates_of_destruction WHERE id = cod_new;
    IF v_res->'inbound_batch'->>'code' <> 'F196-NEW'
       OR v_res->'supplier'->>'name' <> 'fixture 196 supplier'
       OR v_res->'processing'->>'completed_on' <> d_new::text
       OR v_res->'licence'->>'cert_no' <> 'F196-LIC-NEW'
       OR v_res->'inbound_batch'->>'arrival_date' <> (d_new - 10)::text THEN
        RAISE EXCEPTION 'A4 失败:页上的某一格与快照对不上:%', v_res;
    END IF;
    IF v_res->'company'->>'legal_name' IS NULL THEN RAISE EXCEPTION 'A5 失败:页上没有公司名'; END IF;
    r := r || jsonb_build_object('A_valid_token_renders', true);

    -- I · 剥离。★ 逐条点名,而不是"看起来没有" ★
    IF v_res ? 'provenance' OR v_res::text LIKE '%run_ids%' THEN
        RAISE EXCEPTION 'I1 失败:页上带着出处(加工单 uuid)';
    END IF;
    IF v_res::text LIKE '%' || tok_new::text || '%' THEN
        RAISE EXCEPTION 'I2 失败:页上把令牌【回声】出去了';
    END IF;
    IF v_res::text LIKE '%' || cod_new::text || '%' OR v_res::text LIKE '%' || b_new::text || '%' THEN
        RAISE EXCEPTION 'I3 失败:页上带着内部 uuid';
    END IF;
    IF v_res::text LIKE '%' || v_issuer::text || '%' OR v_res->'certificate' ? 'issued_by' THEN
        RAISE EXCEPTION 'I4 失败:页上带着签发人';
    END IF;
    -- 公司只有【纸上印的】那几格 —— 电话/邮箱/网址不在纸上,所以也不在页上
    IF (v_res->'company') ?| ARRAY['phone','email','website'] THEN
        RAISE EXCEPTION 'I5 失败:页上带着公司的电话/邮箱/网址(纸上没有它们)';
    END IF;
    -- 价格/成本/化验/品位/产出批:快照里本来就没有,而白名单让这句话在将来也成立
    IF v_res ?| ARRAY['price','cost','assay','grade','outputs','void_reason'] THEN
        RAISE EXCEPTION 'I6 失败:页上出现了价格/成本/化验/品位/产出/作废原因';
    END IF;
    r := r || jsonb_build_object('I_stripped', true);

    -- ══════════════════════════════════════════════════════════════════════
    -- C · 作废 + 有替代品 → 解析得到,并说出替代证书的【号】
    -- ══════════════════════════════════════════════════════════════════════
    -- ⚠★【这一臂是【今天没有任何生产路径】走得到的,而那正是它必须存在的理由】★⚠
    --   实测(2026-09-08):void_cod 与 refresh_cod_for_batch 【都】把
    --   p_replaced_by 传成 NULL,app/ 与 lib/ 里没有任何一处写 replaced_by_cod_id。
    --   也就是说"顶上来的那一张"这条分支【眼下没有写入者】——
    --   重新签发是它自己的一刀(COD-3),带着它自己的裁定。
    --   本臂因此直接调 void_cod_internal 的第三个参数把那一列填上:
    --   **等到有人写出重发流程的那一天,这一页不能开始撒谎。**
    RESET ROLE;
    PERFORM void_cod_internal(cod_void, 'fixture 196:数据要更正,重发一张', cod_new);
    EXECUTE 'SET LOCAL ROLE anon';
    PERFORM set_config('request.jwt.claims', '', true);
    v_res := cod_verification(tok_void::text);
    RESET ROLE;
    IF v_res->>'result' <> 'ok' THEN
        RAISE EXCEPTION 'C1 失败:一张【作废的】证书解析不出来了 —— 而那张纸还在人手里:%', v_res;
    END IF;
    IF v_res->>'status' <> 'void' THEN RAISE EXCEPTION 'C2 失败:状态是 "%"', v_res->>'status'; END IF;
    IF v_res->'void'->>'replaced_by_code' <>
       (SELECT code FROM certificates_of_destruction WHERE id = cod_new) THEN
        RAISE EXCEPTION 'C3 失败:没有说出替代证书的号:%', v_res->'void';
    END IF;
    -- ★ 作废【原因】绝不许出现 ★ —— 它是内部自由文本
    IF v_res::text LIKE '%数据要更正%' OR v_res::text LIKE '%重发%' THEN
        RAISE EXCEPTION 'C4 失败:页上印出了作废原因';
    END IF;
    r := r || jsonb_build_object('C_void_names_replacement', true);

    -- ══════════════════════════════════════════════════════════════════════
    -- D · 冲销 → 作废且【没有替代品】,页面照直说
    -- ══════════════════════════════════════════════════════════════════════
    RESET ROLE;
    PERFORM void_cod_internal(cod_rev, 'PROCESSING_REVERSED|fixture 196', NULL);
    EXECUTE 'SET LOCAL ROLE anon';
    PERFORM set_config('request.jwt.claims', '', true);
    v_res := cod_verification(tok_rev::text);
    RESET ROLE;
    IF v_res->>'result' <> 'ok' OR v_res->>'status' <> 'void' THEN
        RAISE EXCEPTION 'D1 失败:被冲销作废的证书没有解析出来:%', v_res;
    END IF;
    IF v_res->'void'->>'replaced_by_code' IS NOT NULL THEN
        RAISE EXCEPTION 'D2 失败:没有替代品的那一种,却报出了一个替代号:%', v_res->'void';
    END IF;
    IF NOT (v_res->'void') ? 'replaced_by_code' THEN
        RAISE EXCEPTION 'D3 失败:作废那一格干脆不在 —— 页面分不出"没有替代品"与"不是作废"';
    END IF;
    IF v_res::text LIKE '%PROCESSING_REVERSED%' THEN
        RAISE EXCEPTION 'D4 失败:页上印出了作废原因(那是内部机器码)';
    END IF;
    r := r || jsonb_build_object('D_withdrawn_says_so', true);

    -- ══════════════════════════════════════════════════════════════════════
    -- E · 不认识 与 格式不对 —— 【逐字节相同】的答案
    -- ══════════════════════════════════════════════════════════════════════
    RESET ROLE;
    DELETE FROM cod_verification_failures;   -- 让这一臂从一个干净的预算起手
    EXECUTE 'SET LOCAL ROLE anon';
    PERFORM set_config('request.jwt.claims', '', true);
    v_res  := cod_verification(gen_random_uuid()::text);        -- 格式对,但不存在
    v_res2 := cod_verification('not-a-uuid-at-all');            -- 格式就不对
    RESET ROLE;
    IF v_res::text <> v_res2::text THEN
        RAISE EXCEPTION 'E1 失败:两种失败给了【不同】的答案 —— 那就是一台可以问的机器:% vs %',
            v_res, v_res2;
    END IF;
    IF v_res->>'result' <> 'not_found' THEN RAISE EXCEPTION 'E2 失败:答案是 "%"', v_res; END IF;
    -- NULL 也走同一条路
    EXECUTE 'SET LOCAL ROLE anon';
    v_res2 := cod_verification(NULL);
    RESET ROLE;
    IF v_res::text <> v_res2::text THEN RAISE EXCEPTION 'E3 失败:NULL 令牌的答案不一样:%', v_res2; END IF;
    r := r || jsonb_build_object('E_one_answer_for_every_failure', true);

    -- ══════════════════════════════════════════════════════════════════════
    -- J · 限流:30 次失败之后限流,而【有效令牌照样解析得到】
    -- ══════════════════════════════════════════════════════════════════════
    RESET ROLE;
    DELETE FROM cod_verification_failures;
    EXECUTE 'SET LOCAL ROLE anon';
    PERFORM set_config('request.jwt.claims', '', true);
    FOR v_n IN 1..30 LOOP
        v_res := cod_verification(gen_random_uuid()::text);
        IF v_res->>'result' <> 'not_found' THEN
            RAISE EXCEPTION 'J1 失败:第 % 次失败就被限流了(预算是 30):%', v_n, v_res;
        END IF;
    END LOOP;
    v_res := cod_verification(gen_random_uuid()::text);
    IF v_res->>'result' <> 'throttled' THEN
        RAISE EXCEPTION 'J2 失败:第 31 次失败没有被限流:%', v_res;
    END IF;
    IF (v_res->>'retry_after_seconds')::int <= 0 THEN
        RAISE EXCEPTION 'J3 失败:限流没有说【多久以后再来】:%', v_res;
    END IF;
    -- ★★【这一句是整个限流设计能成立的地方】★★
    --   攻击者拿不出有效令牌,所以他限不掉任何一个真实持有人。
    --   如果这一句红了,这个限流就成了一个人人可用的拒绝服务开关。
    v_res2 := cod_verification(tok_new::text);
    IF v_res2->>'result' <> 'ok' THEN
        RAISE EXCEPTION 'J4 失败:【限流期间有效令牌被拦住了】—— 那是一个人人可用的拒绝服务开关:%', v_res2;
    END IF;
    -- 表【不会长大】:到了预算就不再插入
    RESET ROLE;
    SELECT count(*) INTO v_rows FROM cod_verification_failures;
    IF v_rows <> 30 THEN
        RAISE EXCEPTION 'J5 失败:失败表长到了 % 行 —— 预算之后不该再插入', v_rows;
    END IF;
    DELETE FROM cod_verification_failures;
    r := r || jsonb_build_object('J_rate_limited_but_never_the_holder', true);

    -- ══════════════════════════════════════════════════════════════════════
    -- F · 两张视图对 anon 关着,而【基表里是有行的】
    -- ══════════════════════════════════════════════════════════════════════
    -- ★【空表上的测试什么都不证明,而本刀存在的理由正是那两张视图就是这么
    --   躲过所有人的】★ ANON-0 实测:它们回空【只因为基表没有行】。
    --   所以这一臂先把行【放进去】,再问 anon。
    RESET ROLE;
    INSERT INTO customers (code, legal_name, country) VALUES ('F196-CUS','fixture 196 customer','SG')
    RETURNING id INTO cus;
    INSERT INTO collection_chases (code, customer_id, chased_on, channel, reached, summary,
                                   base_currency, owed_base, on_account_base, net_due_base,
                                   owed_by_currency, owed_buckets, chased_by)
    VALUES ('F196-CH1', cus, CURRENT_DATE - 3, 'phone', true, 'fixture 196 chase',
            'SGD', 1000, 0, 1000, '{}'::jsonb, '{}'::jsonb, v_issuer)
    RETURNING id INTO v_chase;
    INSERT INTO collection_promises (chase_id, promised_amount_ccy, currency, fx_rate,
                                     promised_amount_base, promised_date, created_by)
    VALUES (v_chase, 1000, 'SGD', 1, 1000, CURRENT_DATE - 1, v_issuer);

    INSERT INTO auth.users (id, email) VALUES (emp_user, 'f196@example.test');
    INSERT INTO employees (code, legal_name, work_category, employment_type,
                           employment_status, hire_date, user_id)
    VALUES ('F196-EMP', 'fixture 196 employee', 'office', 'full_time', 'active',
            CURRENT_DATE - 100, emp_user)
    RETURNING id INTO emp;
    INSERT INTO expense_claims (code, employee_id, spend_date, amount_ccy, currency,
                                description, no_receipt_reason, status, created_by)
    VALUES ('F196-EXP', emp, CURRENT_DATE - 2, 42, 'SGD',
            'fixture 196 claim', 'fixture 196:收据丢了', 'submitted', v_issuer);

    -- 【前提自证:基表【真的】有行,而视图【真的】吐得出内容】
    -- 没有这两句,下面那两个 0 可能只是因为库里什么都没有 —— 而那正是
    -- 这两张视图当初躲过所有人的方式。
    SELECT count(*) INTO v_rows FROM collection_promise_status;
    IF v_rows = 0 THEN RAISE EXCEPTION 'F0a 前提不成立:属主读 collection_promise_status 也是空的'; END IF;
    SELECT count(*) INTO v_rows FROM expense_claim_status;
    IF v_rows = 0 THEN RAISE EXCEPTION 'F0b 前提不成立:属主读 expense_claim_status 也是空的'; END IF;
    -- 而且它们确实【装着】那些东西 —— 说明这一臂拦下来的不是空气
    IF NOT EXISTS (SELECT 1 FROM collection_promise_status WHERE customer_name = 'fixture 196 customer')
       OR NOT EXISTS (SELECT 1 FROM expense_claim_status WHERE employee_name = 'fixture 196 employee') THEN
        RAISE EXCEPTION 'F0c 前提不成立:视图里没有本 fixture 造的那一行';
    END IF;

    v_leak := '';
    EXECUTE 'SET LOCAL ROLE anon';
    PERFORM set_config('request.jwt.claims', '', true);
    BEGIN
        EXECUTE 'SELECT count(*) FROM public.collection_promise_status' INTO v_rows;
        IF v_rows > 0 THEN v_leak := v_leak || 'collection_promise_status(' || v_rows || ' 行) '; END IF;
    EXCEPTION WHEN insufficient_privilege THEN NULL;   -- 被拒 = 关上了,正是要的
    END;
    BEGIN
        EXECUTE 'SELECT count(*) FROM public.expense_claim_status' INTO v_rows;
        IF v_rows > 0 THEN v_leak := v_leak || 'expense_claim_status(' || v_rows || ' 行) '; END IF;
    EXCEPTION WHEN insufficient_privilege THEN NULL;
    END;
    RESET ROLE;
    IF v_leak <> '' THEN
        RAISE EXCEPTION 'F1 失败:匿名请求【读到了】上了膛的那两张视图:%', v_leak;
    END IF;
    IF has_table_privilege('anon', 'public.collection_promise_status', 'SELECT')
       OR has_table_privilege('anon', 'public.expense_claim_status', 'SELECT') THEN
        RAISE EXCEPTION 'F2 失败:anon 仍然握着那两张视图的 SELECT —— 授权没有被收回';
    END IF;
    r := r || jsonb_build_object('F_loaded_views_closed_with_rows_present', true);

    -- ══════════════════════════════════════════════════════════════════════
    -- B · 匿名【够不着别的任何东西】
    -- ══════════════════════════════════════════════════════════════════════
    -- 【这一臂是本刀的另一半】上面证的是"那一张证书看得见";这里证的是
    -- "别的什么都看不见" —— 而这一刀往匿名那一面开了一扇门,所以这句话
    -- 必须【在开门之后】重新量一遍,不能引用 ANON-0 那天的数字。
    --
    -- 【断言的是不变量,不是字面量】(README 第 1 条)—— 不写 332、不写 492,
    -- 因为这个库每加一张表就会变。写的是"能出行的关系有几个"与
    -- "anon 能执行的函数是不是【正好那一支】"。
    v_leak := '';
    v_univ := 0;
    FOR v_n, v_err IN
        SELECT row_number() OVER (ORDER BY c.relname), c.relname
          FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
         WHERE n.nspname = 'public' AND c.relkind IN ('r','v','m','p','f')
    LOOP
        v_univ := v_univ + 1;
        EXECUTE 'SET LOCAL ROLE anon';
        BEGIN
            EXECUTE format('SELECT count(*) FROM public.%I', v_err) INTO v_rows;
            IF v_rows > 0 THEN v_leak := v_leak || v_err || '(' || v_rows || ') '; END IF;
        EXCEPTION WHEN OTHERS THEN NULL;   -- 拒绝也是"够不着",与空集同样合格
        END;
        RESET ROLE;
    END LOOP;
    -- ★【数出 0 个关系 = 扫描瞎了,不是"全都合格"】★ 本仓库为这一条付过账。
    IF v_univ = 0 THEN
        RAISE EXCEPTION 'B0 失败:一个关系都没扫到 —— 那是这条扫描断了,不是通过';
    END IF;
    IF v_leak <> '' THEN
        RAISE EXCEPTION 'B1 失败:匿名请求从 % 个关系里读到了行:%', v_univ, v_leak;
    END IF;

    -- 函数那一半:anon 能执行的必须【正好】是那一支
    SELECT COALESCE(string_agg(p.oid::regprocedure::text, ', ' ORDER BY p.proname), '')
      INTO v_fns
      FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
     WHERE n.nspname = 'public' AND p.prokind = 'f'
       AND has_function_privilege('anon', p.oid, 'EXECUTE');
    IF v_fns <> 'cod_verification(text)' THEN
        RAISE EXCEPTION 'B2 失败:anon 能执行的函数不是【正好那一支】,而是:%', v_fns;
    END IF;
    SELECT count(*) INTO v_rows FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
     WHERE n.nspname = 'public' AND p.prokind = 'f';
    IF v_rows = 0 THEN RAISE EXCEPTION 'B3 失败:一个函数都没数到 —— 那是查询断了'; END IF;
    r := r || jsonb_build_object('B_nothing_else_reachable',
                                 jsonb_build_object('relations_swept', v_univ, 'functions_swept', v_rows));

    RAISE NOTICE 'FIXTURE 196 全部通过: %', r::text;
END;
$fixture$;
ROLLBACK;

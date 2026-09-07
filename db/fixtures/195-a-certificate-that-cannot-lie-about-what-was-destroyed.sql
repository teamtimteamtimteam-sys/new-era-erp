-- db/fixtures/195-a-certificate-that-cannot-lie-about-what-was-destroyed.sql
-- COD-1:销毁证书。十条臂,每一条钉住一件【本来会安静地出错】的事。
--
-- ★★【自带数据,一行都不向线上借 —— 这一条是被 gate 抓出来的】★★
-- 第一版拿线上的 IN-2026-0011 / 0013 / 0029 做样本,并断言"11 张空批里只有
-- 3 张是加工空的"。它在【线上】跑得好好的,在【重建库】上当场红:那里一张
-- 进料批都没有。判词【行为断言】点了名 —— 与 fixture 88 抬头记的是同一课
-- (README 第 2 条:每个用例自带数据;重建库才是生产的样子)。
--
-- 【那两个数字没有丢,只是换了地方】11 与 3 是 2026-09-07 对线上量出来的事实,
-- 它属于【那一天的那个库】,不属于一条常设判据 —— 它记在迁移抬头与
-- cod_delivery_completion 的函数注释里。这里改成造出【每一种形状】各一张,
-- 断言判据【只挑中该挑的那些】。那才是可以永远跑下去的东西。
--
-- 臂:
--   A 判据只挑中"被加工空"的那些 —— 注销空的、盘点空的、半加工的都不算
--   B 每一条拒绝都带着【具名理由】,而理由彼此不同
--   C 盘点调整【不】拒绝(带壳过磅那条裁定)
--   D 执照闸:没有行 → 拒;status IS NULL → 仍然拒;active + 号 → 放行
--   E 签发:铸号、铸令牌、冻快照;快照里【没有产出批、没有工序、没有人名】
--   F 无缝编号:第二张接着第一张
--   G 字节档案与已签发证书都冻住(而这两条必须以 postgres 跑 —— 见臂内注)
--   H 作废:要理由、只能从 issued、不幂等、不动字节档案
--   I 【自动成立】与【冲销即自动作废,且没有替代品】
--   J 权限:没有能力的读者被拒;仓储现场拿得到供应商【名字】,却读不到
--     suppliers 与 company_compliance 一行
BEGIN;
DO $fixture$
DECLARE
    r jsonb := '{}'::jsonb;
    -- 三个会话,各自建自己的角色(不借引导角色 —— README 第 2 条)
    v_issuer uuid := gen_random_uuid();
    v_wh     uuid := gen_random_uuid();
    v_ops    uuid := gen_random_uuid();
    v_role_full uuid; v_role_wh uuid; v_role_ops uuid;

    mat uuid; sup uuid;
    b_done uuid; b_part uuid; b_wo uuid; b_adj uuid; b_none uuid; b_auto uuid;
    run_a uuid; run_b uuid; run_c uuid; v_run uuid;
    v_cod uuid; v_cod2 uuid; v_cod3 uuid; v_lic uuid;
    v_code text; v_code2 text; v_snap jsonb; v_res jsonb;
    v_err text; v_status text; v_repl uuid;
    v_supname text; v_rows integer; v_n integer;

    -- 造一张【直接落库】的加工单 + 投料腿 + 消耗流水。
    -- 用裸 INSERT 而不是 commit_processing_run:这几臂要的是【精确的台账形状】,
    -- 不是走一遍加工的全部闸门(那是 I 臂的事,它确实走真路径)。
BEGIN
    -- ══════════════════════════════════════════════════════════════════════
    -- 0 · 自带数据
    -- ══════════════════════════════════════════════════════════════════════
    INSERT INTO roles (code, name_en, name_zh, is_active)
    VALUES ('fixture-195-full', 'fixture', 'fixture', true) RETURNING id INTO v_role_full;
    INSERT INTO role_permissions (role_id, permission_code) SELECT v_role_full, code FROM permissions;
    INSERT INTO user_roles (user_id, role_id) VALUES (v_issuer, v_role_full);

    -- ★【仓储现场与运营两个角色【照播种的授权抄】,不在这里写第二份清单】★
    -- 写死一份就是"谁持有什么"的第二个定义,而它会与 role_permissions.sql
    -- 悄悄分开 —— 那正是 J 臂要测的东西自己先失真。
    INSERT INTO roles (code, name_en, name_zh, is_active)
    VALUES ('fixture-195-warehouse', 'fixture', 'fixture', true) RETURNING id INTO v_role_wh;
    INSERT INTO role_permissions (role_id, permission_code)
    SELECT v_role_wh, rp.permission_code FROM role_permissions rp
      JOIN roles ro ON ro.id = rp.role_id WHERE ro.code = 'warehouse';
    INSERT INTO user_roles (user_id, role_id) VALUES (v_wh, v_role_wh);

    INSERT INTO roles (code, name_en, name_zh, is_active)
    VALUES ('fixture-195-operations', 'fixture', 'fixture', true) RETURNING id INTO v_role_ops;
    INSERT INTO role_permissions (role_id, permission_code)
    SELECT v_role_ops, rp.permission_code FROM role_permissions rp
      JOIN roles ro ON ro.id = rp.role_id WHERE ro.code = 'operations';
    INSERT INTO user_roles (user_id, role_id) VALUES (v_ops, v_role_ops);

    -- 【仓储现场必须持有 action.issue_cod,运营必须【不】持有】—— 这两句是
    -- J 臂的前提,前提不成立时这一臂会"通过"而什么都没测到。
    IF NOT EXISTS (SELECT 1 FROM role_permissions WHERE role_id = v_role_wh
                    AND permission_code = 'action.issue_cod') THEN
        RAISE EXCEPTION 'FIXTURE 195 前提不成立:warehouse 没有 action.issue_cod';
    END IF;
    IF EXISTS (SELECT 1 FROM role_permissions WHERE role_id = v_role_ops
                AND permission_code = 'action.issue_cod') THEN
        RAISE EXCEPTION 'FIXTURE 195 前提不成立:operations 持有了 action.issue_cod,J1 臂将测不到东西';
    END IF;

    -- 公司抬头。★【"有没有行"与"法定名称填没填"是两件事】★
    -- 头一版只问了前者,于是在【重建库】上当场红:那里 company_profile 有一行
    -- (镜像建的),但 legal_name 是空的 —— 签发按名拒 COMPANY_LEGAL_NAME_MISSING。
    -- 而那道拒绝是对的(一张不知道是谁开的对外单据比没有这张纸更糟),
    -- 错的是这份 fixture 的前提判断。所以这里问的是【那个值在不在】。
    IF NOT EXISTS (SELECT 1 FROM company_profile) THEN
        INSERT INTO company_profile (legal_name, registration_no, address_lines, city, postal_code, country)
        VALUES ('Fixture 195 Recovery Pte. Ltd.', 'FX195-UEN', '1 Fixture Road', 'Singapore', '000000', 'Singapore');
    ELSIF NOT EXISTS (SELECT 1 FROM company_profile WHERE btrim(COALESCE(legal_name, '')) <> '') THEN
        UPDATE company_profile SET legal_name = 'Fixture 195 Recovery Pte. Ltd.',
               registration_no = COALESCE(registration_no, 'FX195-UEN'),
               address_lines = COALESCE(address_lines, '1 Fixture Road'),
               city = COALESCE(city, 'Singapore'), country = COALESCE(country, 'Singapore');
    END IF;

    INSERT INTO materials (code, name, kind_code, may_be_processed, form_code, source_code)
    VALUES ('FX195-M', 'fixture 195 material', 'battery_material', true, 'black_mass', 'end_of_life')
    RETURNING id INTO mat;

    INSERT INTO suppliers (code, legal_name, country, counterparty_type)
    VALUES ('FX195-S', 'Fixture 195 Battery Recycle Co.', 'SG', 'goods_supplier')
    RETURNING id INTO sup;

    -- ── 五张形状各不相同的进料批 ──────────────────────────────────────────
    -- 【建的时候 remaining_qty = quantity】—— AFTER INSERT 触发器照此发一条
    -- receipt 流水;之后每一次改余额都【配一条流水】,否则恒等式当场拦下
    -- (那正是它存在的意义)。
    INSERT INTO inbound_batches (code, material_id, supplier_id, quantity, unit, remaining_qty,
                                 arrival_date, source_reason_code, source_reason_note)
    VALUES ('FX195-DONE', mat, sup, 100, 'kg', 100, CURRENT_DATE - 30, 'other', 'fixture 195'),
           ('FX195-PART', mat, sup, 100, 'kg', 100, CURRENT_DATE - 30, 'other', 'fixture 195'),
           ('FX195-WO',   mat, sup, 100, 'kg', 100, CURRENT_DATE - 30, 'other', 'fixture 195'),
           ('FX195-ADJ',  mat, sup, 100, 'kg', 100, CURRENT_DATE - 30, 'other', 'fixture 195'),
           ('FX195-NONE', mat, sup, 100, 'kg', 100, CURRENT_DATE - 30, 'other', 'fixture 195'),
           ('FX195-AUTO', mat, sup, 100, 'kg', 100, CURRENT_DATE - 30, 'other', 'fixture 195');
    SELECT id INTO b_done FROM inbound_batches WHERE code = 'FX195-DONE';
    SELECT id INTO b_part FROM inbound_batches WHERE code = 'FX195-PART';
    SELECT id INTO b_wo   FROM inbound_batches WHERE code = 'FX195-WO';
    SELECT id INTO b_adj  FROM inbound_batches WHERE code = 'FX195-ADJ';
    SELECT id INTO b_none FROM inbound_batches WHERE code = 'FX195-NONE';
    SELECT id INTO b_auto FROM inbound_batches WHERE code = 'FX195-AUTO';

    -- ★【每一张都要记安全状态,否则投料腿被起火闸按名拒】★
    -- guard_processing_input:*"一条安全状态都没有的意思是【没有人记过】,
    -- 不是'这批货安全'"* —— 那道闸是对的,这里只是把前提摆对。
    -- discharged_verified 是 manual_disassembly 受理的那一个。
    INSERT INTO inbound_batch_safety_states (inbound_batch_id, safety_state_code)
    SELECT id, 'discharged_verified' FROM inbound_batches WHERE code LIKE 'FX195-%';

    -- FX195-DONE:整批被【一张活着的加工单】吃掉 → 判据应当说"成立"
    INSERT INTO processing_runs (process_date, total_input, total_output, loss_qty, status,
                                 allocation_basis, operation_type_code, created_by)
    VALUES (CURRENT_DATE - 10, 100, 80, 20, 'committed', 'weight', 'manual_disassembly', v_issuer)
    RETURNING id INTO run_a;
    INSERT INTO processing_inputs (run_id, inbound_batch_id, quantity_consumed) VALUES (run_a, b_done, 100);
    INSERT INTO inventory_movements (inbound_batch_id, movement_type, qty_delta, run_id, business_date, created_by)
    VALUES (b_done, 'processing_consume', -100, run_a, CURRENT_DATE - 10, v_issuer);
    UPDATE inbound_batches SET remaining_qty = 0 WHERE id = b_done;

    -- FX195-PART:只吃掉 60,还剩 40 → "还没整批加工完"
    INSERT INTO processing_runs (process_date, total_input, total_output, loss_qty, status,
                                 allocation_basis, operation_type_code, created_by)
    VALUES (CURRENT_DATE - 9, 60, 50, 10, 'committed', 'weight', 'manual_disassembly', v_issuer)
    RETURNING id INTO run_b;
    INSERT INTO processing_inputs (run_id, inbound_batch_id, quantity_consumed) VALUES (run_b, b_part, 60);
    INSERT INTO inventory_movements (inbound_batch_id, movement_type, qty_delta, run_id, business_date, created_by)
    VALUES (b_part, 'processing_consume', -60, run_b, CURRENT_DATE - 9, v_issuer);
    UPDATE inbound_batches SET remaining_qty = 40 WHERE id = b_part;

    -- FX195-ADJ:整批被吃掉,【而且流水史里还有一对盘点调整】→ 仍然"成立"
    INSERT INTO processing_runs (process_date, total_input, total_output, loss_qty, status,
                                 allocation_basis, operation_type_code, created_by)
    VALUES (CURRENT_DATE - 8, 100, 75, 25, 'committed', 'weight', 'manual_disassembly', v_issuer)
    RETURNING id INTO run_c;
    INSERT INTO processing_inputs (run_id, inbound_batch_id, quantity_consumed) VALUES (run_c, b_adj, 100);
    INSERT INTO inventory_movements (inbound_batch_id, movement_type, qty_delta, run_id, business_date, created_by)
    VALUES (b_adj, 'processing_consume', -100, run_c, CURRENT_DATE - 8, v_issuer);
    INSERT INTO inventory_movements (inbound_batch_id, movement_type, qty_delta, business_date, created_by)
    VALUES (b_adj, 'adjustment', 3, CURRENT_DATE - 7, v_issuer),
           (b_adj, 'adjustment', -3, CURRENT_DATE - 7, v_issuer);
    UPDATE inbound_batches SET remaining_qty = 0 WHERE id = b_adj;

    -- FX195-NONE:一克没加工过,余额被一条盘点调整清零 → 绝不能读成"加工完了"
    INSERT INTO inventory_movements (inbound_batch_id, movement_type, qty_delta, business_date, created_by)
    VALUES (b_none, 'adjustment', -100, CURRENT_DATE - 6, v_issuer);
    UPDATE inbound_batches SET remaining_qty = 0 WHERE id = b_none;

    -- FX195-WO:整批注销 —— 走【门】(软删函数会写 writeoff 流水并把余额清零)
    PERFORM set_config('request.jwt.claims', format('{"sub":"%s","role":"authenticated"}', v_issuer), true);
    PERFORM soft_delete_inbound_batch(b_wo, 'fixture 195:这一票货是报废的,不是加工掉的');

    SET CONSTRAINTS ALL IMMEDIATE;   -- 恒等式当场校验;末尾改回 DEFERRED(见 C 臂尾注)

    -- ══════════════════════════════════════════════════════════════════════
    -- A · 判据只挑中【被加工空】的那些
    -- ══════════════════════════════════════════════════════════════════════
    -- 六张批次里有 4 张 remaining_qty = 0(DONE / ADJ / NONE / WO),
    -- 而只有 2 张是【被加工空】的。这个 4 与 2 的差就是本刀的全部要害:
    -- 按 remaining_qty 签发,等于替 NONE 和 WO 两张撒谎。
    SELECT count(*) INTO v_n FROM inbound_batches
     WHERE code LIKE 'FX195-%' AND remaining_qty = 0;
    IF v_n <> 4 THEN RAISE EXCEPTION 'A0 前提不成立:自带数据里空批应为 4 张,实得 %', v_n; END IF;

    SELECT count(*) INTO v_n FROM inbound_batches
     WHERE code LIKE 'FX195-%' AND (cod_delivery_completion(id)->>'complete')::boolean;
    IF v_n <> 2 THEN
        RAISE EXCEPTION 'A1 失败:判据挑中 % 张,应为 2(DONE 与 ADJ)', v_n;
    END IF;
    IF NOT (cod_delivery_completion(b_done)->>'complete')::boolean THEN RAISE EXCEPTION 'A2 失败:整批加工完的那张没被挑中'; END IF;
    IF (cod_delivery_completion(b_none)->>'complete')::boolean THEN RAISE EXCEPTION 'A3 失败:一克没加工过、被盘点清零的那张被判成了"加工完"'; END IF;
    IF (cod_delivery_completion(b_wo)->>'complete')::boolean   THEN RAISE EXCEPTION 'A4 失败:被注销的那张被判成了"加工完"'; END IF;
    r := r || jsonb_build_object('A_zero_remaining', 4, 'A_truly_complete', 2);

    -- ══════════════════════════════════════════════════════════════════════
    -- B · 每一条拒绝都带着【具名理由】,而理由彼此不同
    -- ══════════════════════════════════════════════════════════════════════
    IF (cod_delivery_completion(b_wo)->>'reason')   <> 'DELIVERY_WRITTEN_OFF' THEN
        RAISE EXCEPTION 'B1 失败:注销批的理由是 %', cod_delivery_completion(b_wo)->>'reason'; END IF;
    IF (cod_delivery_completion(b_part)->>'reason') <> 'DELIVERY_NOT_FULLY_PROCESSED' THEN
        RAISE EXCEPTION 'B2 失败:半加工批的理由是 %', cod_delivery_completion(b_part)->>'reason'; END IF;
    -- ★ 顺序本身是内容 ★:一票原封不动的货,"一克都没加工过"比"还没加工完"说得准。
    IF (cod_delivery_completion(b_none)->>'reason') <> 'NOTHING_PROCESSED' THEN
        RAISE EXCEPTION 'B3 失败:未加工批的理由是 %', cod_delivery_completion(b_none)->>'reason'; END IF;
    r := r || jsonb_build_object(
        'B_written_off',   cod_delivery_completion(b_wo)->>'reason',
        'B_partly_done',   cod_delivery_completion(b_part)->>'reason',
        'B_adjusted_only', cod_delivery_completion(b_none)->>'reason');

    -- ══════════════════════════════════════════════════════════════════════
    -- C · 盘点调整【不】拒绝
    -- ══════════════════════════════════════════════════════════════════════
    -- Tim 2026-09-07 的裁定:电池【带壳过磅】,加工量是【拆壳之后】才算的,
    -- 账实差是常态。判据因此不看 adjustment,也不设任何阈值。
    IF NOT EXISTS (SELECT 1 FROM inventory_movements
                    WHERE inbound_batch_id = b_adj AND movement_type = 'adjustment') THEN
        RAISE EXCEPTION 'C0 失败:盘点调整没造出来,这一臂什么都没考';
    END IF;
    IF NOT (cod_delivery_completion(b_adj)->>'complete')::boolean THEN
        RAISE EXCEPTION 'C 失败:流水史里有盘点调整就把证书判成了不成立(理由 %)',
            cod_delivery_completion(b_adj)->>'reason';
    END IF;
    r := r || jsonb_build_object('C_adjustment_tolerated', true);

    -- ══════════════════════════════════════════════════════════════════════
    -- D · 执照闸
    -- ══════════════════════════════════════════════════════════════════════
    -- 先让两张成立的证书真的成立 —— 上面几张加工单是裸 INSERT 造的,没走
    -- commit_processing_run,所以挂钩没开火。这里显式叫一次(它是幂等的)。
    PERFORM refresh_cod_for_batch(b_done);
    PERFORM refresh_cod_for_batch(b_adj);
    SELECT id INTO v_cod  FROM certificates_of_destruction WHERE inbound_batch_id = b_done;
    SELECT id INTO v_cod2 FROM certificates_of_destruction WHERE inbound_batch_id = b_adj;
    IF v_cod IS NULL OR v_cod2 IS NULL THEN RAISE EXCEPTION 'D0 失败:证书没有成立'; END IF;
    IF (SELECT code FROM certificates_of_destruction WHERE id = v_cod) IS NOT NULL THEN
        RAISE EXCEPTION 'D0b 失败:一张从未签发的证书带着号';
    END IF;
    -- 【没成立的那几张不许有证书】
    IF EXISTS (SELECT 1 FROM certificates_of_destruction
                WHERE inbound_batch_id IN (b_part, b_wo, b_none)) THEN
        RAISE EXCEPTION 'D0c 失败:判据不成立的批次也长出了证书';
    END IF;

    EXECUTE 'SET LOCAL ROLE authenticated';
    PERFORM set_config('request.jwt.claims', format('{"sub":"%s","role":"authenticated"}', v_issuer), true);

    -- D1:执照表里没有在效的 GWDF 行 → 拒,而且拒绝里带着【去哪儿录】
    v_err := NULL;
    BEGIN PERFORM issue_cod(v_cod); EXCEPTION WHEN OTHERS THEN v_err := SQLERRM; END;
    IF v_err IS NULL THEN RAISE EXCEPTION 'D1 失败:没有执照却签发成功了'; END IF;
    IF v_err NOT LIKE 'COD_LICENCE_NOT_RECORDED|/purchasing/licences%' THEN
        RAISE EXCEPTION 'D1 失败:拒绝的措辞是 "%"', v_err;
    END IF;
    r := r || jsonb_build_object('D1_no_licence_refused', true);

    -- D2:有号、但 status IS NULL —— 【没有人说过】不是 active
    -- ★【COD-2 改了这一行的两个日期,而那不是化妆】★ 原来写的是
    --   valid_from = CURRENT_DATE - 1,而这几票货的加工完成日是 CURRENT_DATE - 10
    --   —— 也就是说这份 fixture 自己的前提是【一张在货物加工完之后才生效的执照】。
    --   COD-1 的闸不看日期,所以它一路绿;COD-2 的闸两端都看,于是它当场变红
    --   (COD_LICENCE_NOT_YET_IN_FORCE)。**变红的是前提,不是被测的规则。**
    --   按 README 第 5 条(前提要显式设定)把有效期设成真的盖住完成日。
    RESET ROLE;
    INSERT INTO company_compliance (cert_type_code, cert_no, issuing_body, status, valid_from, valid_until)
    VALUES ('gwdf', 'FX195-GWDF', 'NEA', NULL, CURRENT_DATE - 400, CURRENT_DATE + 365)
    RETURNING id INTO v_lic;
    EXECUTE 'SET LOCAL ROLE authenticated';
    PERFORM set_config('request.jwt.claims', format('{"sub":"%s","role":"authenticated"}', v_issuer), true);
    v_err := NULL;
    BEGIN PERFORM issue_cod(v_cod); EXCEPTION WHEN OTHERS THEN v_err := SQLERRM; END;
    IF v_err IS NULL THEN
        RAISE EXCEPTION 'D2 失败:status IS NULL 的执照行放行了签发 —— NULL 被读成了 active';
    END IF;
    -- ★【COD-2:这一句拒绝换了名字,而【断言的东西一个字没变】】★
    --   COD-1 只有一句 COD_LICENCE_NOT_RECORDED,它同时代表"没有行"与"行不合格"。
    --   COD-2 把它拆成六句(补救的办法各不相同,所以名字必须各不相同),
    --   而"有一行盖住了这一天、但它不是 active"这一种从此叫 COD_LICENCE_NOT_ACTIVE。
    --   本臂要钉的仍然是那一句:**status IS NULL 是【没有人说过】,不是 active。**
    IF v_err NOT LIKE 'COD_LICENCE_NOT_ACTIVE%' THEN RAISE EXCEPTION 'D2 失败:措辞是 "%"', v_err; END IF;
    r := r || jsonb_build_object('D2_null_status_refused', true);

    RESET ROLE;
    UPDATE company_compliance SET status = 'active' WHERE id = v_lic;

    -- ══════════════════════════════════════════════════════════════════════
    -- E · 签发
    -- ══════════════════════════════════════════════════════════════════════
    EXECUTE 'SET LOCAL ROLE authenticated';
    PERFORM set_config('request.jwt.claims', format('{"sub":"%s","role":"authenticated"}', v_issuer), true);
    v_res  := issue_cod(v_cod);
    v_code := v_res->>'code';
    IF v_code !~ '^COD-[0-9]{4}-[0-9]{4}$' THEN RAISE EXCEPTION 'E1 失败:号是 "%"', v_code; END IF;
    SELECT snapshot INTO v_snap FROM certificates_of_destruction WHERE id = v_cod;
    IF v_snap IS NULL THEN RAISE EXCEPTION 'E2 失败:签发了却没有快照'; END IF;
    IF (SELECT verification_token FROM certificates_of_destruction WHERE id = v_cod) IS NULL THEN
        RAISE EXCEPTION 'E3 失败:签发了却没有核验令牌';
    END IF;

    -- ★ 快照里【不许】有产出批、加工单、血缘、化验、人名 ★
    IF v_snap::text ~ 'OUT-[0-9]{4}-'  THEN RAISE EXCEPTION 'E4 失败:快照里有产出批号'; END IF;
    IF v_snap::text ~ 'PROC-[0-9]{4}-' THEN RAISE EXCEPTION 'E5 失败:快照里有加工单号'; END IF;
    IF v_snap ?| ARRAY['runs','chain','recovery','assay','outputs'] THEN
        RAISE EXCEPTION 'E6 失败:快照里有工序/血缘/回收/化验/产出的块';
    END IF;
    -- 供应商【只有名字与编号】—— 没有地址、没有联系方式
    IF (v_snap->'supplier') ?| ARRAY['address_lines','city','contact','email','phone','postal_code','country'] THEN
        RAISE EXCEPTION 'E7 失败:快照里带上了供应商的地址或联系方式';
    END IF;
    IF v_snap->'supplier'->>'name' <> 'Fixture 195 Battery Recycle Co.' THEN
        RAISE EXCEPTION 'E8 失败:快照里的供应商名是 "%"', v_snap->'supplier'->>'name';
    END IF;
    -- 执照【是在组装时读出来的】,不是一个开关
    IF v_snap->'licence'->>'cert_no' <> 'FX195-GWDF' THEN
        RAISE EXCEPTION 'E9 失败:快照里的执照号是 "%"', v_snap->'licence'->>'cert_no';
    END IF;
    -- 数量是【过磅的那个数】(100),不是消耗量、也不是申报量
    IF (v_snap->'inbound_batch'->>'quantity')::numeric <> 100 THEN
        RAISE EXCEPTION 'E10 失败:纸上的数量是 %,应为过磅的 100',
            v_snap->'inbound_batch'->>'quantity';
    END IF;
    -- 加工完成日期【冻在快照里】—— 它是派生的,冲销之后就再也算不回来了
    IF v_snap->'certificate'->>'completed_on' IS NULL THEN
        RAISE EXCEPTION 'E11 失败:快照里没有冻住加工完成日期';
    END IF;
    r := r || jsonb_build_object('E_code', v_code, 'E_snapshot_clean', true,
                                 'E_licence_in_snapshot', v_snap->'licence'->>'cert_no',
                                 'E_quantity', v_snap->'inbound_batch'->>'quantity');

    -- ══════════════════════════════════════════════════════════════════════
    -- F · 无缝编号
    -- ══════════════════════════════════════════════════════════════════════
    v_code2 := (issue_cod(v_cod2))->>'code';
    IF v_code2 = v_code THEN RAISE EXCEPTION 'F1 失败:两张证书拿到同一个号 %', v_code; END IF;
    IF split_part(v_code2,'-',3)::int <> split_part(v_code,'-',3)::int + 1 THEN
        RAISE EXCEPTION 'F2 失败:号不连 —— % 之后是 %', v_code, v_code2;
    END IF;
    r := r || jsonb_build_object('F_second_code', v_code2);

    -- ══════════════════════════════════════════════════════════════════════
    -- G · 字节档案与已签发证书都冻住
    -- ══════════════════════════════════════════════════════════════════════
    PERFORM record_cod_issue(v_cod2, 'cod/' || v_cod2::text || '/x.pdf', repeat('a', 64));

    -- ★【这几条必须以 postgres 跑,而那本身就是一个发现】★
    -- 头一版写在 authenticated 会话里,结果 UPDATE 【匹配到零行就静静过去了】——
    -- 两张表都只有 SELECT 策略,没有 UPDATE 策略,于是 RLS 在触发器之前就把行
    -- 滤没了,append-only 守卫【一次都没被考到】。而 service_role / postgres
    -- 都 rolbypassrls:真正绕得过 RLS 的那条路上,守卫才是唯一的拦阻。
    RESET ROLE;
    v_err := NULL;
    BEGIN UPDATE cod_issues SET sha256 = repeat('b', 64) WHERE cod_id = v_cod2;
    EXCEPTION WHEN OTHERS THEN v_err := SQLERRM; END;
    IF v_err IS NULL THEN RAISE EXCEPTION 'G1 失败:字节档案被改掉了,守卫没开火'; END IF;
    IF v_err NOT LIKE 'COD_ISSUE_IMMUTABLE%' THEN RAISE EXCEPTION 'G1 失败:措辞是 "%"', v_err; END IF;

    v_err := NULL;
    BEGIN DELETE FROM cod_issues WHERE cod_id = v_cod2;
    EXCEPTION WHEN OTHERS THEN v_err := SQLERRM; END;
    IF v_err IS NULL THEN RAISE EXCEPTION 'G1b 失败:字节档案被删掉了'; END IF;

    v_err := NULL;
    BEGIN UPDATE certificates_of_destruction SET snapshot = '{}'::jsonb WHERE id = v_cod2;
    EXCEPTION WHEN OTHERS THEN v_err := SQLERRM; END;
    IF v_err IS NULL THEN RAISE EXCEPTION 'G2 失败:已签发证书的快照被改掉了'; END IF;
    IF v_err NOT LIKE 'COD_ISSUED_IMMUTABLE%' THEN RAISE EXCEPTION 'G2 失败:措辞是 "%"', v_err; END IF;
    r := r || jsonb_build_object('G_archive_append_only', true, 'G_archive_no_delete', true,
                                 'G_snapshot_frozen', true);

    -- ══════════════════════════════════════════════════════════════════════
    -- H · 作废
    -- ══════════════════════════════════════════════════════════════════════
    EXECUTE 'SET LOCAL ROLE authenticated';
    PERFORM set_config('request.jwt.claims', format('{"sub":"%s","role":"authenticated"}', v_issuer), true);
    v_err := NULL;
    BEGIN PERFORM void_cod(v_cod2, '   '); EXCEPTION WHEN OTHERS THEN v_err := SQLERRM; END;
    IF v_err IS NULL THEN RAISE EXCEPTION 'H1 失败:没有理由的作废通过了'; END IF;
    IF v_err NOT LIKE 'REASON_REQUIRED%' THEN RAISE EXCEPTION 'H1 失败:措辞是 "%"', v_err; END IF;

    PERFORM void_cod(v_cod2, '供应商名称录错了,另发一张');
    SELECT status INTO v_status FROM certificates_of_destruction WHERE id = v_cod2;
    IF v_status <> 'void' THEN RAISE EXCEPTION 'H2 失败:作废之后状态是 %', v_status; END IF;
    -- 【作废不动字节档案一个字】—— 供应商手里那份仍然查得到
    IF NOT EXISTS (SELECT 1 FROM cod_issues WHERE cod_id = v_cod2) THEN
        RAISE EXCEPTION 'H3 失败:作废把字节档案带走了';
    END IF;
    -- 【号码不回收】
    IF (SELECT code FROM certificates_of_destruction WHERE id = v_cod2) IS NULL THEN
        RAISE EXCEPTION 'H3b 失败:作废把号码抹掉了 —— 供应商手里那张纸会查无此物';
    END IF;
    -- 【不幂等】
    v_err := NULL;
    BEGIN PERFORM void_cod(v_cod2, '再作废一次'); EXCEPTION WHEN OTHERS THEN v_err := SQLERRM; END;
    IF v_err IS NULL THEN RAISE EXCEPTION 'H4 失败:作废是幂等的'; END IF;
    IF v_err NOT LIKE 'COD_NOT_ISSUED%' THEN RAISE EXCEPTION 'H4 失败:措辞是 "%"', v_err; END IF;
    r := r || jsonb_build_object('H_void', v_status, 'H_archive_survives', true);

    -- ══════════════════════════════════════════════════════════════════════
    -- I · 【自动成立】,与【冲销即自动作废,且没有替代品】
    -- ══════════════════════════════════════════════════════════════════════
    -- 这一臂钉两件事,而它们是同一条裁定的两半:
    --   ① 一票货【整批加工完的那一刻】,未签发的证书自己就成立了 ——
    --      不等谁打开页面(Tim:它像化验报告一样【必须存在】);
    --   ② 加工单一冲销,已签发的证书【自己作废,而且没有替代品】——
    --      没有人需要记得去作废。
    -- 【这一臂走真路径】上面几张是裸 INSERT 造的台账形状;这里过
    -- commit_processing_run 的全部闸门,因为要考的正是【挂钩有没有开火】。
    RESET ROLE;
    -- 【恒等式改回 DEFERRED】C 臂为了当场看余额设了 IMMEDIATE。不改回去,
    -- rollback_processing_run 会在【还原进料那一行 UPDATE 上】被恒等式拦下
    -- (它先改 remaining_qty、再写还原流水,中间那一瞬两边本来就对不上 ——
    -- 这正是那个约束 DEFERRABLE INITIALLY DEFERRED 的全部理由)。
    -- 报出来会是 LEDGER_INVARIANT,读起来像加工代码坏了,其实是这份 fixture
    -- 自己把闸提前了。
    SET CONSTRAINTS ALL DEFERRED;

    IF EXISTS (SELECT 1 FROM certificates_of_destruction WHERE inbound_batch_id = b_auto) THEN
        RAISE EXCEPTION 'I0 失败:FX195-AUTO 一克没加工过,却已经有证书了';
    END IF;

    EXECUTE 'SET LOCAL ROLE authenticated';
    PERFORM set_config('request.jwt.claims', format('{"sub":"%s","role":"authenticated"}', v_issuer), true);

    -- 【整批吃掉】—— 拆一票带壳过磅的货:投 100,出 80,20 是壳(loss_qty)。
    -- 那 20 公斤【不产生任何库存流水】,所以判据看到的是"全量走了投料这扇门"。
    v_run := commit_processing_run(
        CURRENT_DATE, 'fixture 195:整批拆解', 20,
        jsonb_build_array(jsonb_build_object('inbound_batch_id', b_auto, 'quantity_consumed', 100)),
        jsonb_build_array(jsonb_build_object('material_id', mat, 'quantity', 80)),
        'weight', NULL, NULL, 'manual_disassembly');

    -- ① 证书【自己成立了】
    SELECT id, status INTO v_cod3, v_status
      FROM certificates_of_destruction WHERE inbound_batch_id = b_auto;
    IF v_cod3 IS NULL THEN
        RAISE EXCEPTION 'I1 失败:整批加工完了,证书没有自己成立 —— 它不该等谁打开页面';
    END IF;
    IF v_status <> 'pending' THEN RAISE EXCEPTION 'I2 失败:刚成立的证书状态是 %', v_status; END IF;
    IF (SELECT code FROM certificates_of_destruction WHERE id = v_cod3) IS NOT NULL THEN
        RAISE EXCEPTION 'I3 失败:自动成立的证书带着号 —— 没寄出去的东西不消耗号码';
    END IF;
    r := r || jsonb_build_object('I_auto_created', true, 'I_status_on_creation', v_status);

    -- 签发它,好让冲销那一半有东西可作废
    v_code2 := (issue_cod(v_cod3))->>'code';

    -- ② 冲销 → 自动作废,没有替代品
    PERFORM rollback_processing_run(v_run, 'fixture 195:钉住冲销即作废这一条');
    RESET ROLE;

    SELECT status, replaced_by_cod_id, void_reason INTO v_status, v_repl, v_err
      FROM certificates_of_destruction WHERE id = v_cod3;
    IF v_status <> 'void' THEN
        RAISE EXCEPTION 'I4 失败:加工单冲销了,证书还是 % —— 那张纸还在说着一件系统已经不信的事', v_status;
    END IF;
    IF v_repl IS NOT NULL THEN
        RAISE EXCEPTION 'I5 失败:因冲销作废却挂了一张替代证书 —— 冲销说的是那次加工没发生';
    END IF;
    IF v_err NOT LIKE 'PROCESSING_REVERSED%' THEN RAISE EXCEPTION 'I6 失败:作废理由是 "%"', v_err; END IF;
    IF (SELECT code FROM certificates_of_destruction WHERE id = v_cod3) IS NULL THEN
        RAISE EXCEPTION 'I7 失败:作废把号码抹掉了';
    END IF;
    r := r || jsonb_build_object('I_voided_on_reversal', true, 'I_reason', v_err,
                                 'I_replacement', 'none', 'I_number_kept', v_code2);

    -- ② b:【软删也作废】注销掉的料不是被处理掉的。
    --   FX195-DONE 的证书是已签发的;把那票货注销掉,它必须自己作废。
    EXECUTE 'SET LOCAL ROLE authenticated';
    PERFORM set_config('request.jwt.claims', format('{"sub":"%s","role":"authenticated"}', v_issuer), true);
    PERFORM soft_delete_inbound_batch(b_done, 'fixture 195:注销一票已经开过证书的货');
    RESET ROLE;
    SELECT status INTO v_status FROM certificates_of_destruction WHERE id = v_cod;
    IF v_status <> 'void' THEN
        RAISE EXCEPTION 'I8 失败:料注销了,证书还是 % —— 它说的是"我们处理了你的料"', v_status;
    END IF;
    r := r || jsonb_build_object('I_voided_on_writeoff', true);

    -- ══════════════════════════════════════════════════════════════════════
    -- J · 权限
    -- ══════════════════════════════════════════════════════════════════════
    -- J1:没有 action.issue_cod 的读者 —— 运营角色 —— 被按名拒
    EXECUTE 'SET LOCAL ROLE authenticated';
    PERFORM set_config('request.jwt.claims', format('{"sub":"%s","role":"authenticated"}', v_ops), true);
    v_err := NULL;
    BEGIN PERFORM cod_certificate_data(b_part); EXCEPTION WHEN OTHERS THEN v_err := SQLERRM; END;
    IF v_err IS NULL THEN RAISE EXCEPTION 'J1 失败:一个没有 action.issue_cod 的读者组装出了证书'; END IF;
    IF v_err <> 'PERMISSION_DENIED' THEN RAISE EXCEPTION 'J1 失败:措辞是 "%"', v_err; END IF;
    RESET ROLE;
    r := r || jsonb_build_object('J1_no_capability_refused', true);

    -- J2:★ fixture 83 的那个形状,在本刀的方向上 ★
    -- 仓储现场【拿得到供应商的名字】(它是随单据走的展示标签),
    -- 【却仍然一行 suppliers 都读不到】。两件事必须同时成立 ——
    -- 只满足前者就是开了第二扇门,只满足后者证书就没有主体。
    EXECUTE 'SET LOCAL ROLE authenticated';
    PERFORM set_config('request.jwt.claims', format('{"sub":"%s","role":"authenticated"}', v_wh), true);
    v_supname := cod_certificate_data(b_adj)->'supplier'->>'name';
    SELECT count(*) INTO v_rows FROM suppliers;
    RESET ROLE;
    IF v_supname IS NULL OR btrim(v_supname) = '' THEN
        RAISE EXCEPTION 'J2a 失败:仓储现场组装证书时拿不到供应商名字 —— 证书没有主体';
    END IF;
    IF v_rows <> 0 THEN
        RAISE EXCEPTION 'J2b 失败:仓储现场直接读 suppliers 读到了 % 行 —— 本刀开了第二扇门', v_rows;
    END IF;
    r := r || jsonb_build_object('J2_supplier_name_via_function', v_supname,
                                 'J2_supplier_rows_direct', v_rows);

    -- J3:仓储现场【读不到 company_compliance】,却仍然被执照闸管着
    EXECUTE 'SET LOCAL ROLE authenticated';
    PERFORM set_config('request.jwt.claims', format('{"sub":"%s","role":"authenticated"}', v_wh), true);
    SELECT count(*) INTO v_rows FROM company_compliance;
    RESET ROLE;
    IF v_rows <> 0 THEN
        RAISE EXCEPTION 'J3 失败:仓储现场读到了 % 行执照 —— 本刀顺手放宽了合规', v_rows;
    END IF;
    r := r || jsonb_build_object('J3_compliance_rows_for_warehouse', 0);

    -- J4:★【三支内层函数对 authenticated【够不着】】★ gate 的 B2 抓过它们:
    --   void_cod_internal 没有调用者检查,留着 EXECUTE 就等于任何登录用户
    --   都能作废任何一张已签发的证书,完全绕开 action.issue_cod。
    --   收回之后靠的是【真的够不着】—— 这一臂钉住那句话。
    FOR v_err IN SELECT unnest(ARRAY['void_cod_internal','refresh_cod_for_batch','cod_delivery_completion'])
    LOOP
        IF has_function_privilege('authenticated',
               (SELECT p.oid FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
                 WHERE n.nspname = 'public' AND p.proname = v_err), 'EXECUTE') THEN
            RAISE EXCEPTION 'J4 失败:authenticated 仍然调得到 % —— 那是一扇没人看守的侧门', v_err;
        END IF;
    END LOOP;
    r := r || jsonb_build_object('J4_internal_functions_unreachable', 3);

    -- ★【NOTICE,不是 EXCEPTION —— 而这是两条不同的跑法】★
    -- 经 Management API 单跑时,惯例是 RAISE EXCEPTION 'FIXTURE_REPORT %',
    -- 因为报告只能从错误消息里带回来,顺带把一切回滚。
    -- 但 gate 是【用 psql 跑的】,它按退出码判 —— 一句 EXCEPTION 会被读成失败,
    -- 而这份 fixture 第一版正是这样"通过着红掉"的。
    -- 整支已经包在 BEGIN/ROLLBACK 里,回滚由文末那一行负责,报告用 NOTICE 出。
    RAISE NOTICE 'FIXTURE 195 全部通过:%', r::text;
END
$fixture$;
ROLLBACK;

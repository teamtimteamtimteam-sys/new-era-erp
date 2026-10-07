-- 252 MES-3b:一张标签先记下来再打印,补印要理由;标签上的物料名跟着单据走;一次扫码只说你看得见的那一部分;
--     发货可以扫一次核对;危险品与 HS 编码印到发货单与发货队列上,没给只提示;要隔离的状态只标不拒(MES-3b Step 0 Q0–Q31;v1.4.40)
--
-- ═══════════════════════════════════════════════════════════════════════════
-- 【本支钉住的东西】一臂一组裁定;每一臂都有故障注入(db/scripts/2026-10-07-mes3b-fixture-injections.py)必须让它红在它点名的那一臂。
--   PRINT    record_label_print:第一次 —— 不要理由、记下模板与纸(默认 = 那一种东西启用着、排第一的那张 A6)、份数、二维码路径、
--            印上去的字段快照、谁;第二次不给理由 → LABEL_REPRINT_REASON_REQUIRED|<批号>(什么都不留);给了理由 → 补印、理由记下、
--            第几次;A5 模板照记 A5;别的种类的模板 / 停用的模板 → LABEL_TEMPLATE_INVALID;份数 0 → LABEL_COPIES_INVALID;
--            预览什么都不写(Q6–Q8)
--   GATE     谁印得了:那样东西自己的查看码 —— 没有 → PERMISSION_DENIED|<码>(不告诉他那样东西在不在);找不到 → LABEL_OBJECT_NOT_FOUND;
--            库位标签要库存查看码(Q28)
--   NAME     ★ 一个持进料查看码、【没有】物料与供应商查看码的读者:直接读物料表一行都读不到(对照:缺陷真的存在),
--            而他的标签上物料名与供应商名都在(Q2 的并入:展示标签跟着单据走)
--   LINK     /b/ 与 /loc/ 的四种结果:没登录 → signed_out(不记日志)· 看得见 → found + id · 看不见 → restricted、【没有 id】、
--            说要哪个码 · 没有这个编号 → unknown;旧标签上的地址(/inbound/<id>/edit)照样认得;/b/ 只认批次(Q9)
--   RESOLVE  光秃秃的编号(批号不分大小写)· 带域名与查询串的短链接 · %xx 解开 · 空的 → unreadable · 库位带在用与隔离两个标记(Q18 · Q19)
--   LOG      每一次解析一行 scan_events(场合、方式、原文、结果;id 只在 found 时记);scan_events 与 label_prints 只追加
--            (改、删、清空都按名拒,连属主也拒);scan_events 不进变更记录(豁免名单里有它、它一行变更记录都没有),
--            label_prints 进(Q20 · Q27)
--   MOVE     转移照旧经 create_stock_transfer:从一个一点这批货都没有的库位转 → IOD_TRANSFER_EXCEEDS_BUCKET;
--            要隔离的批移去普通库位 → QUARANTINE_LOCATION_REQUIRED(MES-3a 的闸一字未动);扫出来的库位 id 转得进去(Q22)
--   SHIP     ship_order:带一个不对的核对扫码 → SHIP_SCAN_MISMATCH|<扫到的>|<该发的>(一行都不发);带对的(小写也算)→ 发;
--            不带 → 照发(Q24)
--   DG       电池料没选编号:标签、发货单行、发货队列都说 dg_missing,发货不被拒;选了 UN3480 → 三处都带编号与第 9 类(Q12–Q15)
--   HS       materials_hs_code_shape:6–12 位数字、可带点;5 位、13 位、带字母、点结尾都拒;发货单行带 hs_code(Q17)
--   QUAR     产出批身上开着鼓包或漏液:发货队列与发货单行都标出 quarantine_states,发货【不】被拒(Q16)
--   PV       V30(四个编号,三列任一为空)· V31 · V35(每一种没删的电池料);给了就消失;不持物料查看码的人一行都看不见(Q29)
--
-- nea_waste_categories 在镜像检查的两张清单里(Q3)不是一个库里证得了的事 —— 它由注入脚本把它从 BOOTSTRAP_MAY_BE_EMPTY 里拿掉、
-- 让 gate --offline 的 bootstrap 那一行红来证。
--
-- 自带数据(README 第 2 条)。以 postgres 跑(绕过 RLS)—— 员工的读写真的切成 authenticated + 那个人的 JWT。
-- 会改状态的"能不能过"一律放进 f252_try(失败的那一次整句回滚);要看记录的才真写。
-- ═══════════════════════════════════════════════════════════════════════════

BEGIN;
SET LOCAL statement_timeout = '300s';

CREATE FUNCTION pg_temp.f252_as(p_user uuid) RETURNS void
LANGUAGE sql AS $f$
    SELECT set_config('request.jwt.claims',
                      CASE WHEN p_user IS NULL THEN '' ELSE format('{"sub":"%s","role":"authenticated"}', p_user) END, true)
$f$;

-- 以某人的身份跑一句;成功回 'OK'(改动留着),失败回错误原文(没名字的 42501 回 '42501')
CREATE FUNCTION pg_temp.f252_try(p_user uuid, p_sql text) RETURNS text
LANGUAGE plpgsql AS $f$
DECLARE v_back text := current_setting('request.jwt.claims', true);
BEGIN
    PERFORM pg_temp.f252_as(p_user);
    EXECUTE 'SET LOCAL ROLE authenticated';
    EXECUTE p_sql;
    EXECUTE 'RESET ROLE';
    PERFORM set_config('request.jwt.claims', COALESCE(v_back, ''), true);
    RETURN 'OK';
EXCEPTION WHEN OTHERS THEN
    EXECUTE 'RESET ROLE';
    PERFORM set_config('request.jwt.claims', COALESCE(v_back, ''), true);
    RETURN CASE WHEN SQLSTATE = '42501' AND SQLERRM NOT LIKE 'PERMISSION_DENIED%' THEN '42501' ELSE SQLERRM END;
END;
$f$;

-- 以某人的身份读一个 jsonb;读不出来就抛,带着臂名 —— 一次失败不许被读成 0 或 NULL
CREATE FUNCTION pg_temp.f252_read(p_arm text, p_user uuid, p_sql text) RETURNS jsonb
LANGUAGE plpgsql AS $f$
DECLARE v jsonb; v_back text := current_setting('request.jwt.claims', true);
BEGIN
    PERFORM pg_temp.f252_as(p_user);
    EXECUTE 'SET LOCAL ROLE authenticated';
    EXECUTE p_sql INTO v;
    EXECUTE 'RESET ROLE';
    PERFORM set_config('request.jwt.claims', COALESCE(v_back, ''), true);
    RETURN v;
EXCEPTION WHEN OTHERS THEN
    EXECUTE 'RESET ROLE';
    PERFORM set_config('request.jwt.claims', COALESCE(v_back, ''), true);
    RAISE EXCEPTION 'FIXTURE 252 %: the read failed: % — %', p_arm, SQLSTATE, SQLERRM;
END;
$f$;

-- 一次扫码(以某人的身份),回解析的结果
CREATE FUNCTION pg_temp.f252_scan(p_user uuid, p_value text, p_ctx text DEFAULT 'lookup', p_method text DEFAULT 'keyboard') RETURNS jsonb
LANGUAGE plpgsql AS $f$
BEGIN
    RETURN pg_temp.f252_read('RESOLVE', p_user, format('SELECT resolve_scan_code(%L, %L, %L)', p_value, p_ctx, p_method));
END;
$f$;

DO $$
DECLARE
    u_all  uuid := gen_random_uuid();   -- 全部码
    u_wh   uuid := gen_random_uuid();   -- 仓库的形状:进料 / 产出 / 库存查看与库存编辑、发货、物流 —— 【没有】物料与供应商查看码
    u_inb  uuid := gen_random_uuid();   -- 只看进料
    u_none uuid := gen_random_uuid();   -- 一个码都没有
    r_all uuid; r_wh uuid; r_inb uuid; r_none uuid;
    d date := (now() AT TIME ZONE 'Asia/Singapore')::date;
    v_base text;
    sup uuid; m_bat uuid; m_pack uuid; m_bm uuid;
    l1 uuid; l2 uuid; l_off uuid; lq uuid;
    b uuid; b_code text; bq uuid; ob uuid; ob_code text; ob2 uuid;
    so uuid; sl1 uuid; sl2 uuid; sl3 uuid; res1 uuid; res2 uuid; res3 uuid;
    v_j jsonb; v_msg text; v_n int; v_m int; v_t text; v_x uuid; v_seq bigint;
BEGIN
    UPDATE finance_settings SET locked_before = NULL, system_start_date = NULL;
    SELECT code INTO v_base FROM currencies WHERE is_base;

    -- ══════════════ 布景 ══════════════
    INSERT INTO auth.users (id, email, email_confirmed_at, created_at) VALUES
        (u_all, 'fx252-all@test.local', now(), now()), (u_wh, 'fx252-wh@test.local', now(), now()),
        (u_inb, 'fx252-inb@test.local', now(), now()), (u_none, 'fx252-none@test.local', now(), now());
    INSERT INTO roles (code, name_en, name_zh, is_active) VALUES ('fx252-all', 'f', 'f', true) RETURNING id INTO r_all;
    INSERT INTO roles (code, name_en, name_zh, is_active) VALUES ('fx252-wh', 'f', 'f', true) RETURNING id INTO r_wh;
    INSERT INTO roles (code, name_en, name_zh, is_active) VALUES ('fx252-inb', 'f', 'f', true) RETURNING id INTO r_inb;
    INSERT INTO roles (code, name_en, name_zh, is_active) VALUES ('fx252-none', 'f', 'f', true) RETURNING id INTO r_none;
    INSERT INTO role_permissions (role_id, permission_code) SELECT r_all, code FROM permissions;
    INSERT INTO role_permissions (role_id, permission_code) VALUES
        (r_wh, 'module.inbound.view'), (r_wh, 'module.output.view'), (r_wh, 'module.inventory.view'), (r_wh, 'module.inventory.edit'),
        (r_wh, 'action.ship_goods'), (r_wh, 'module.logistics.view'), (r_inb, 'module.inbound.view');
    INSERT INTO user_roles (user_id, role_id) VALUES (u_all, r_all), (u_wh, r_wh), (u_inb, r_inb), (u_none, r_none);
    -- 审批关着(本支测的不是审批链):放行生下来就是 approved(fixture 224 的 O 臂)
    PERFORM set_config('evoltrya.approvals_policy_ctx', '1', true);
    UPDATE finance_settings SET approvals_enabled = false;
    PERFORM pg_temp.f252_as(u_all);

    INSERT INTO suppliers (code, legal_name, country, status, counterparty_type)
    VALUES ('ZZ252-S', 'f252 supplier legal name', 'SG', 'active', 'goods_supplier') RETURNING id INTO sup;
    INSERT INTO materials (code, name, kind_code, may_be_processed, form_code, source_code, size_format_code)
    VALUES ('ZZ252-BAT', 'f252 battery packs', 'battery_material', true, 'whole_pack', 'end_of_life', 'ev_traction') RETURNING id INTO m_bat;
    INSERT INTO materials (code, name, kind_code, may_be_processed, unit)
    VALUES ('ZZ252-PACK', 'f252 pallets', 'packaging', false, 'kg') RETURNING id INTO m_pack;
    INSERT INTO materials (code, name, kind_code, may_be_processed, form_code, source_code, unit)
    VALUES ('ZZ252-BM', 'f252 black mass', 'battery_material', true, 'black_mass', 'end_of_life', 'kg') RETURNING id INTO m_bm;
    INSERT INTO storage_locations (code, name, is_active) VALUES ('ZZ252-L1', 'f252 rack one', true) RETURNING id INTO l1;
    INSERT INTO storage_locations (code, name, is_active) VALUES ('zz252-l2', 'f252 rack two', true) RETURNING id INTO l2;
    INSERT INTO storage_locations (code, name, is_active) VALUES ('ZZ252 OFF', 'f252 retired', false) RETURNING id INTO l_off;
    INSERT INTO storage_locations (code, name, is_active, is_quarantine) VALUES ('ZZ252-Q', 'f252 quarantine', true, true) RETURNING id INTO lq;

    -- 一张进料批,收进 L1(供应商与物料的名字是标签要印的)
    b := (pg_temp.f252_read('PRINT', u_all, format(
        $q$SELECT create_inbound_batch(p_material_id => %L, p_supplier_id => %L, p_quantity => 800, p_unit => 'kg', p_arrival_date => %L,
              p_location_id => %L, p_chemistry_certainty => 'single_known', p_source_reason_code => 'other',
              p_source_reason_note => 'fixture 252') -> 'batch_id'$q$, m_bat, sup, d, l1))) #>> '{}';
    SELECT code INTO b_code FROM inbound_batches WHERE id = b;

    -- ══════════════ PV · 一开始:四个编号都缺三列(V30)· 两种电池料没有 HS(V31)· 没有编号(V35);包装料不在其中 ══════════════
    v_j := pg_temp.f252_read('PV', u_all, $q$SELECT jsonb_agg(value_code || ':' || item_code ORDER BY value_code, item_code) FROM pending_values
                                              WHERE value_code IN ('V30', 'V31', 'V35') AND (value_code = 'V30' OR item_code LIKE 'ZZ252%')$q$);
    IF v_j IS DISTINCT FROM '["V30:UN3090", "V30:UN3091", "V30:UN3480", "V30:UN3481", "V31:ZZ252-BAT", "V31:ZZ252-BM", "V35:ZZ252-BAT", "V35:ZZ252-BM"]'::jsonb THEN
        RAISE EXCEPTION 'FIXTURE 252 PV: the opening pending values are wrong: %', v_j; END IF;
    v_n := (pg_temp.f252_read('PV', u_wh, $q$SELECT to_jsonb(count(*)) FROM pending_values WHERE value_code IN ('V30', 'V31', 'V35')$q$))::int;
    IF v_n <> 0 THEN RAISE EXCEPTION 'FIXTURE 252 PV: a reader without materials view sees % V30/V31/V35 row(s)', v_n; END IF;

    -- ══════════════ GATE · 谁印得了 ══════════════
    v_msg := pg_temp.f252_try(u_none, format('SELECT label_print_preview(%L, %L)', 'inbound_batch', b));
    IF v_msg IS DISTINCT FROM 'PERMISSION_DENIED|module.inventory.view' THEN
        RAISE EXCEPTION 'FIXTURE 252 GATE: a reader with no code previewed a label: %', v_msg; END IF;
    v_msg := pg_temp.f252_try(u_inb, format('SELECT label_print_preview(%L, %L)', 'storage_location', l1));
    IF v_msg IS DISTINCT FROM 'PERMISSION_DENIED|module.inventory.view' THEN
        RAISE EXCEPTION 'FIXTURE 252 GATE: a location label without inventory view: %', v_msg; END IF;
    v_msg := pg_temp.f252_try(u_inb, format('SELECT label_print_preview(%L, %L)', 'output_batch', gen_random_uuid()));
    IF v_msg IS DISTINCT FROM 'PERMISSION_DENIED|module.output.view' THEN
        RAISE EXCEPTION 'FIXTURE 252 GATE: an output label without output view should be refused before it is looked up: %', v_msg; END IF;
    v_msg := pg_temp.f252_try(u_inb, format('SELECT label_print_preview(%L, %L)', 'inbound_batch', gen_random_uuid()));
    IF v_msg IS DISTINCT FROM 'LABEL_OBJECT_NOT_FOUND|inbound_batch' THEN
        RAISE EXCEPTION 'FIXTURE 252 GATE: a batch that does not exist: %', v_msg; END IF;
    v_msg := pg_temp.f252_try(u_all, format('SELECT label_print_preview(%L, %L)', 'pallet', b));
    IF v_msg IS DISTINCT FROM 'LABEL_KIND_INVALID|pallet' THEN
        RAISE EXCEPTION 'FIXTURE 252 GATE: an unknown kind: %', v_msg; END IF;

    -- ══════════════ NAME · 一个没有物料 / 供应商查看码的读者,标签上照样有物料名与供应商名 ══════════════
    v_n := (pg_temp.f252_read('NAME', u_inb, format($q$SELECT to_jsonb(count(*)) FROM materials WHERE id = %L$q$, m_bat)))::int;
    IF v_n <> 0 THEN RAISE EXCEPTION 'FIXTURE 252 NAME: control — this reader was expected NOT to read materials directly'; END IF;
    v_j := pg_temp.f252_read('NAME', u_inb, format('SELECT label_print_preview(%L, %L)', 'inbound_batch', b));
    IF v_j #>> '{data,material_name}' IS DISTINCT FROM 'f252 battery packs'
       OR v_j #>> '{data,detail_value}' IS DISTINCT FROM 'f252 supplier legal name'
       OR v_j #>> '{data,detail_kind}' IS DISTINCT FROM 'supplier' OR v_j #>> '{data,code}' IS DISTINCT FROM b_code THEN
        RAISE EXCEPTION 'FIXTURE 252 NAME: the label lost the material or supplier name for a reader without those codes: %', v_j -> 'data'; END IF;

    -- ══════════════ PRINT · 预览什么都不写;第一次;补印要理由;补印;A5;错的模板;份数 ══════════════
    IF v_j #>> '{template,code}' IS DISTINCT FROM 'inbound_a6' OR v_j #>> '{template,page_size}' IS DISTINCT FROM 'A6'
       OR v_j ->> 'qr_path' IS DISTINCT FROM '/b/' || b_code OR (v_j ->> 'next_is_reprint')::boolean IS DISTINCT FROM false THEN
        RAISE EXCEPTION 'FIXTURE 252 PRINT: the preview should default to the A6 inbound template, a /b/ link and no prior print: %', v_j; END IF;
    IF EXISTS (SELECT 1 FROM label_prints) THEN RAISE EXCEPTION 'FIXTURE 252 PRINT: a preview wrote a print row'; END IF;

    v_j := pg_temp.f252_read('PRINT', u_inb, format('SELECT record_label_print(%L, %L, NULL, 2, %L)', 'inbound_batch', b, 'ignored on a first print'));
    SELECT count(*) INTO v_n FROM label_prints WHERE inbound_batch_id = b;
    SELECT to_jsonb(lp) INTO v_j FROM label_prints lp WHERE inbound_batch_id = b;
    IF v_n <> 1 OR v_j ->> 'object_kind' IS DISTINCT FROM 'inbound_batch' OR (v_j ->> 'is_reprint')::boolean IS DISTINCT FROM false
       OR v_j ->> 'reprint_reason' IS NOT NULL OR v_j ->> 'template_code' IS DISTINCT FROM 'inbound_a6' OR v_j ->> 'page_size' IS DISTINCT FROM 'A6'
       OR (v_j ->> 'copies')::int IS DISTINCT FROM 2 OR v_j ->> 'qr_payload' IS DISTINCT FROM '/b/' || b_code
       OR v_j ->> 'printed_by' IS DISTINCT FROM u_inb::text
       OR v_j #>> '{printed_fields,material_name}' IS DISTINCT FROM 'f252 battery packs'
       OR v_j #>> '{printed_fields,detail_value}' IS DISTINCT FROM 'f252 supplier legal name'
       OR v_j #>> '{printed_fields,template,code}' IS DISTINCT FROM 'inbound_a6' THEN
        RAISE EXCEPTION 'FIXTURE 252 PRINT: the first print recorded the wrong thing: %', v_j; END IF;

    v_msg := pg_temp.f252_try(u_inb, format('SELECT record_label_print(%L, %L, NULL, 1, %L)', 'inbound_batch', b, '   '));
    IF v_msg IS DISTINCT FROM 'LABEL_REPRINT_REASON_REQUIRED|' || b_code THEN
        RAISE EXCEPTION 'FIXTURE 252 PRINT: a reprint with a blank reason: %', v_msg; END IF;
    v_msg := pg_temp.f252_try(u_inb, format('SELECT record_label_print(%L, %L)', 'inbound_batch', b));
    IF v_msg IS DISTINCT FROM 'LABEL_REPRINT_REASON_REQUIRED|' || b_code THEN
        RAISE EXCEPTION 'FIXTURE 252 PRINT: a reprint with no reason at all: %', v_msg; END IF;
    IF (SELECT count(*) FROM label_prints WHERE inbound_batch_id = b) <> 1 THEN
        RAISE EXCEPTION 'FIXTURE 252 PRINT: a refused reprint left a row'; END IF;

    v_j := pg_temp.f252_read('PRINT', u_inb, format('SELECT record_label_print(%L, %L, %L, NULL, %L)', 'inbound_batch', b, 'inbound_a5', '  label torn by the forklift  '));
    IF (v_j ->> 'is_reprint')::boolean IS DISTINCT FROM true OR (v_j ->> 'print_no')::int IS DISTINCT FROM 2 THEN
        RAISE EXCEPTION 'FIXTURE 252 PRINT: the reprint should say print 2, a reprint: %', v_j; END IF;
    SELECT to_jsonb(lp) INTO v_j FROM label_prints lp WHERE inbound_batch_id = b AND is_reprint;
    IF v_j ->> 'reprint_reason' IS DISTINCT FROM 'label torn by the forklift' OR v_j ->> 'template_code' IS DISTINCT FROM 'inbound_a5'
       OR v_j ->> 'page_size' IS DISTINCT FROM 'A5' OR (v_j ->> 'copies')::int IS DISTINCT FROM 1 THEN
        RAISE EXCEPTION 'FIXTURE 252 PRINT: the reprint recorded the wrong thing: %', v_j; END IF;
    v_j := pg_temp.f252_read('PRINT', u_inb, format('SELECT label_print_preview(%L, %L)', 'inbound_batch', b));
    IF (v_j ->> 'prints_so_far')::int IS DISTINCT FROM 2 OR (v_j ->> 'next_is_reprint')::boolean IS DISTINCT FROM true THEN
        RAISE EXCEPTION 'FIXTURE 252 PRINT: after two prints the preview should ask for a reason: %', v_j; END IF;

    v_msg := pg_temp.f252_try(u_all, format('SELECT record_label_print(%L, %L, %L, 1, %L)', 'inbound_batch', b, 'output_a6', 'r'));
    IF v_msg IS DISTINCT FROM 'LABEL_TEMPLATE_INVALID|output_a6' THEN
        RAISE EXCEPTION 'FIXTURE 252 PRINT: an output template on an inbound batch: %', v_msg; END IF;
    UPDATE label_templates SET is_active = false WHERE code = 'inbound_a5';
    v_msg := pg_temp.f252_try(u_all, format('SELECT record_label_print(%L, %L, %L, 1, %L)', 'inbound_batch', b, 'inbound_a5', 'r'));
    IF v_msg IS DISTINCT FROM 'LABEL_TEMPLATE_INVALID|inbound_a5' THEN
        RAISE EXCEPTION 'FIXTURE 252 PRINT: a deactivated template: %', v_msg; END IF;
    UPDATE label_templates SET is_active = true WHERE code = 'inbound_a5';
    v_msg := pg_temp.f252_try(u_all, format('SELECT record_label_print(%L, %L, NULL, 0, %L)', 'inbound_batch', b, 'r'));
    IF v_msg IS DISTINCT FROM 'LABEL_COPIES_INVALID|0' THEN
        RAISE EXCEPTION 'FIXTURE 252 PRINT: zero copies: %', v_msg; END IF;
    -- 模板只有库存编辑码改得动
    v_msg := pg_temp.f252_try(u_inb, $q$UPDATE label_templates SET name_en = 'x' WHERE code = 'inbound_a6'$q$);
    IF v_msg NOT LIKE '%module.inventory.edit%' THEN
        RAISE EXCEPTION 'FIXTURE 252 PRINT: a template edit without inventory edit was not refused by name: %', v_msg; END IF;
    -- 库位标签:库存查看码就够
    v_j := pg_temp.f252_read('PRINT', u_wh, format('SELECT record_label_print(%L, %L)', 'storage_location', l1));
    IF v_j #>> '{template,code}' IS DISTINCT FROM 'location_a6' OR v_j ->> 'qr_path' IS DISTINCT FROM '/loc/ZZ252-L1'
       OR (SELECT count(*) FROM label_prints WHERE storage_location_id = l1) <> 1 THEN
        RAISE EXCEPTION 'FIXTURE 252 PRINT: a location label: %', v_j; END IF;

    -- ══════════════ LINK · /b/ 与 /loc/ 的四种结果 ══════════════
    SELECT count(*) INTO v_n FROM scan_events;
    v_j := pg_temp.f252_read('LINK', NULL, format('SELECT resolve_scan_code(%L, %L, %L)', '/b/' || b_code, 'lookup', 'link'));
    IF v_j ->> 'outcome' IS DISTINCT FROM 'signed_out' OR (SELECT count(*) FROM scan_events) <> v_n THEN
        RAISE EXCEPTION 'FIXTURE 252 LINK: signed out should be signed_out and leave no log row: %', v_j; END IF;
    v_j := pg_temp.f252_scan(u_inb, '/b/' || b_code, 'lookup', 'link');
    IF v_j ->> 'outcome' IS DISTINCT FROM 'found' OR v_j ->> 'kind' IS DISTINCT FROM 'inbound_batch' OR v_j ->> 'id' IS DISTINCT FROM b::text THEN
        RAISE EXCEPTION 'FIXTURE 252 LINK: /b/ for a reader who may view: %', v_j; END IF;
    v_j := pg_temp.f252_scan(u_none, '/b/' || b_code, 'lookup', 'link');
    IF v_j ->> 'outcome' IS DISTINCT FROM 'restricted' OR v_j ->> 'id' IS NOT NULL OR v_j ->> 'needs' IS DISTINCT FROM 'module.inbound.view'
       OR v_j ->> 'kind' IS DISTINCT FROM 'inbound_batch' OR v_j ->> 'code' IS DISTINCT FROM b_code THEN
        RAISE EXCEPTION 'FIXTURE 252 LINK: /b/ for a reader who may not view must name the code and give no id: %', v_j; END IF;
    v_j := pg_temp.f252_scan(u_all, '/b/IN-1999-0000', 'lookup', 'link');
    IF v_j ->> 'outcome' IS DISTINCT FROM 'unknown' OR v_j ->> 'id' IS NOT NULL THEN
        RAISE EXCEPTION 'FIXTURE 252 LINK: an unknown code: %', v_j; END IF;
    v_j := pg_temp.f252_scan(u_all, '/b/ZZ252-L1', 'lookup', 'link');
    IF v_j ->> 'outcome' IS DISTINCT FROM 'unknown' THEN
        RAISE EXCEPTION 'FIXTURE 252 LINK: /b/ must only resolve batches, a location code gave %', v_j; END IF;
    v_j := pg_temp.f252_scan(u_wh, 'https://new-era-erp.vercel.app/inbound/' || b::text || '/edit', 'lookup', 'camera');
    IF v_j ->> 'outcome' IS DISTINCT FROM 'found' OR v_j ->> 'id' IS DISTINCT FROM b::text OR v_j ->> 'code' IS DISTINCT FROM b_code THEN
        RAISE EXCEPTION 'FIXTURE 252 LINK: an old label (edit-page URL) should still resolve: %', v_j; END IF;
    v_j := pg_temp.f252_scan(u_none, 'https://x.example/inbound/' || b::text || '/edit');
    IF v_j ->> 'outcome' IS DISTINCT FROM 'restricted' OR v_j ->> 'id' IS NOT NULL THEN
        RAISE EXCEPTION 'FIXTURE 252 LINK: an old label read by someone who may not view: %', v_j; END IF;
    v_j := pg_temp.f252_scan(u_wh, '/loc/ZZ252-Q', 'lookup', 'link');
    IF v_j ->> 'outcome' IS DISTINCT FROM 'found' OR v_j ->> 'kind' IS DISTINCT FROM 'storage_location' OR v_j ->> 'id' IS DISTINCT FROM lq::text
       OR (v_j ->> 'is_quarantine')::boolean IS DISTINCT FROM true OR (v_j ->> 'is_active')::boolean IS DISTINCT FROM true THEN
        RAISE EXCEPTION 'FIXTURE 252 LINK: /loc/ for a reader who may view: %', v_j; END IF;
    v_j := pg_temp.f252_scan(u_inb, '/loc/ZZ252-Q', 'lookup', 'link');
    IF v_j ->> 'outcome' IS DISTINCT FROM 'restricted' OR v_j ->> 'id' IS NOT NULL OR v_j ->> 'needs' IS DISTINCT FROM 'module.inventory.view'
       OR v_j ? 'is_quarantine' THEN
        RAISE EXCEPTION 'FIXTURE 252 LINK: /loc/ for a reader who may not view must give no id and no flags: %', v_j; END IF;
    v_j := pg_temp.f252_scan(u_wh, '/loc/NOPE-252', 'lookup', 'link');
    IF v_j ->> 'outcome' IS DISTINCT FROM 'unknown' THEN RAISE EXCEPTION 'FIXTURE 252 LINK: an unknown location: %', v_j; END IF;

    -- ══════════════ RESOLVE · 写法 ══════════════
    v_j := pg_temp.f252_scan(u_wh, '  ' || lower(b_code) || E'\n', 'transfer');
    IF v_j ->> 'outcome' IS DISTINCT FROM 'found' OR v_j ->> 'code' IS DISTINCT FROM b_code THEN
        RAISE EXCEPTION 'FIXTURE 252 RESOLVE: a bare lower-case batch code with whitespace: %', v_j; END IF;
    v_j := pg_temp.f252_scan(u_wh, 'https://new-era-erp.vercel.app/b/' || b_code || '?from=label#top');
    IF v_j ->> 'outcome' IS DISTINCT FROM 'found' OR v_j ->> 'id' IS DISTINCT FROM b::text THEN
        RAISE EXCEPTION 'FIXTURE 252 RESOLVE: a full short link with a query and a fragment: %', v_j; END IF;
    v_j := pg_temp.f252_scan(u_wh, 'http://localhost:3000/loc/ZZ252%20OFF', 'receipt');
    IF v_j ->> 'outcome' IS DISTINCT FROM 'found' OR v_j ->> 'id' IS DISTINCT FROM l_off::text OR (v_j ->> 'is_active')::boolean IS DISTINCT FROM false THEN
        RAISE EXCEPTION 'FIXTURE 252 RESOLVE: a percent-encoded location code (inactive): %', v_j; END IF;
    v_j := pg_temp.f252_scan(u_wh, 'ZZ252-L2', 'transfer');
    IF v_j ->> 'outcome' IS DISTINCT FROM 'found' OR v_j ->> 'id' IS DISTINCT FROM l2::text OR v_j ->> 'code' IS DISTINCT FROM 'zz252-l2' THEN
        RAISE EXCEPTION 'FIXTURE 252 RESOLVE: a location code in another case (unique) should resolve: %', v_j; END IF;
    v_j := pg_temp.f252_scan(u_wh, '   ');
    IF v_j ->> 'outcome' IS DISTINCT FROM 'unreadable' OR v_j ->> 'kind' IS NOT NULL THEN
        RAISE EXCEPTION 'FIXTURE 252 RESOLVE: an empty scan: %', v_j; END IF;

    -- ══════════════ LOG · 每一次一行;只追加;scan_events 不进变更记录,label_prints 进 ══════════════
    SELECT count(*) INTO v_m FROM scan_events WHERE scanned_by IN (u_all, u_wh, u_inb, u_none);
    IF v_m <> 14 THEN RAISE EXCEPTION 'FIXTURE 252 LOG: expected 14 scan rows (one per resolve, none when signed out), got %', v_m; END IF;
    IF EXISTS (SELECT 1 FROM scan_events WHERE outcome <> 'found' AND resolved_id IS NOT NULL) THEN
        RAISE EXCEPTION 'FIXTURE 252 LOG: a scan row that was not found carries an id'; END IF;
    SELECT to_jsonb(s) INTO v_j FROM scan_events s WHERE scanned_by = u_none AND raw_value = '/b/' || b_code;
    IF v_j ->> 'outcome' IS DISTINCT FROM 'restricted' OR v_j ->> 'resolved_kind' IS DISTINCT FROM 'inbound_batch' OR v_j ->> 'resolved_id' IS NOT NULL
       OR v_j ->> 'method' IS DISTINCT FROM 'link' OR v_j ->> 'context' IS DISTINCT FROM 'lookup' OR v_j ->> 'parsed_code' IS DISTINCT FROM b_code THEN
        RAISE EXCEPTION 'FIXTURE 252 LOG: the restricted scan row is wrong: %', v_j; END IF;
    IF NOT EXISTS (SELECT 1 FROM scan_events WHERE scanned_by = u_wh AND context = 'receipt' AND method = 'keyboard' AND resolved_id = l_off) THEN
        RAISE EXCEPTION 'FIXTURE 252 LOG: the receipt-context scan was not recorded with its context and id'; END IF;
    v_msg := pg_temp.f252_try(u_all, $q$UPDATE scan_events SET outcome = 'found'$q$);
    IF v_msg IS DISTINCT FROM 'APPEND_ONLY|scan_events|update' THEN RAISE EXCEPTION 'FIXTURE 252 LOG: scan_events update: %', v_msg; END IF;
    v_msg := pg_temp.f252_try(u_all, $q$DELETE FROM label_prints$q$);
    IF v_msg IS DISTINCT FROM 'APPEND_ONLY|label_prints|delete' THEN RAISE EXCEPTION 'FIXTURE 252 LOG: label_prints delete: %', v_msg; END IF;
    BEGIN
        DELETE FROM scan_events;
        RAISE EXCEPTION 'FIXTURE 252 LOG: the owner deleted scan_events';
    EXCEPTION WHEN OTHERS THEN
        IF SQLERRM IS DISTINCT FROM 'APPEND_ONLY|scan_events|delete' THEN RAISE; END IF;
    END;
    BEGIN
        TRUNCATE label_prints;
        RAISE EXCEPTION 'FIXTURE 252 LOG: the owner truncated label_prints';
    EXCEPTION WHEN OTHERS THEN
        IF SQLERRM IS DISTINCT FROM 'APPEND_ONLY|label_prints|truncate' THEN RAISE; END IF;
    END;
    v_msg := pg_temp.f252_try(u_all, $q$INSERT INTO scan_events (context, method, raw_value, outcome) VALUES ('lookup', 'keyboard', 'x', 'unknown')$q$);
    IF v_msg IS DISTINCT FROM '42501' THEN RAISE EXCEPTION 'FIXTURE 252 LOG: a direct insert into scan_events: %', v_msg; END IF;
    IF EXISTS (SELECT 1 FROM change_log WHERE table_name = 'scan_events') THEN
        RAISE EXCEPTION 'FIXTURE 252 LOG: scan_events was written to the change log'; END IF;
    IF NOT EXISTS (SELECT 1 FROM change_log_exclusions() e(t, r) WHERE e.t = 'scan_events') THEN
        RAISE EXCEPTION 'FIXTURE 252 LOG: scan_events is not in the exclusion list'; END IF;
    IF (SELECT count(*) FROM change_log WHERE table_name = 'label_prints' AND op = 'INSERT' AND row_key ->> 'id' IS NOT NULL) < 3 THEN
        RAISE EXCEPTION 'FIXTURE 252 LOG: label_prints inserts were not change-logged with their id'; END IF;
    IF jsonb_array_length(change_log_coverage_gaps() -> 'gaps') <> 0 THEN
        RAISE EXCEPTION 'FIXTURE 252 LOG: change-log coverage gaps: %', change_log_coverage_gaps(); END IF;

    -- ══════════════ MOVE · 转移照旧;扫出来的 id 转得进去 ══════════════
    v_x := (pg_temp.f252_scan(u_wh, 'ZZ252-L2', 'transfer') ->> 'id')::uuid;
    v_msg := pg_temp.f252_try(u_wh, format('SELECT create_stock_transfer(%s, %L, %L, NULL, %L)', 10, l1, b, v_x));
    IF v_msg NOT LIKE 'IOD_TRANSFER_EXCEEDS_BUCKET%' THEN
        RAISE EXCEPTION 'FIXTURE 252 MOVE: a transfer from a location holding none of the batch: %', v_msg; END IF;
    v_msg := pg_temp.f252_try(u_wh, format('SELECT create_stock_transfer(%s, %L, %L, NULL, %L)', 100, v_x, b, l1));
    IF v_msg IS DISTINCT FROM 'OK' THEN RAISE EXCEPTION 'FIXTURE 252 MOVE: a scanned transfer L1 → L2 was refused: %', v_msg; END IF;
    IF (SELECT sum(qty_delta) FROM inventory_movements WHERE inbound_batch_id = b AND location_id = l2) IS DISTINCT FROM 100 THEN
        RAISE EXCEPTION 'FIXTURE 252 MOVE: the scanned transfer did not land 100 in L2'; END IF;
    v_msg := pg_temp.f252_try(u_wh, format('SELECT create_stock_transfer(%s, %L, %L, NULL, %L)', 10, l_off, b, l1));
    IF v_msg NOT LIKE 'IOD_TRANSFER_TO_INACTIVE%' THEN RAISE EXCEPTION 'FIXTURE 252 MOVE: into an inactive location: %', v_msg; END IF;
    bq := (pg_temp.f252_read('MOVE', u_all, format(
        $q$SELECT create_inbound_batch(p_material_id => %L, p_supplier_id => %L, p_quantity => 50, p_unit => 'kg', p_arrival_date => %L,
              p_location_id => %L, p_safety_states => ARRAY['swollen_leaking'], p_chemistry_certainty => 'single_known',
              p_source_reason_code => 'other', p_source_reason_note => 'fixture 252') -> 'batch_id'$q$, m_bat, sup, d, lq))) #>> '{}';
    v_msg := pg_temp.f252_try(u_wh, format('SELECT create_stock_transfer(%s, %L, %L, NULL, %L)', 5, l2, bq, lq));
    IF v_msg NOT LIKE 'QUARANTINE_LOCATION_REQUIRED|swollen_leaking|%' THEN
        RAISE EXCEPTION 'FIXTURE 252 MOVE: the MES-3a quarantine gate on a transfer: %', v_msg; END IF;

    -- ══════════════ DG · HS(物料上)══════════════
    v_j := pg_temp.f252_read('DG', u_wh, format('SELECT label_print_preview(%L, %L)', 'inbound_batch', b));
    IF (v_j #>> '{data,dg_missing}')::boolean IS DISTINCT FROM true OR v_j #> '{data,dg}' IS DISTINCT FROM 'null'::jsonb THEN
        RAISE EXCEPTION 'FIXTURE 252 DG: a battery material with no DG code should say dg_missing on the label: %', v_j -> 'data'; END IF;
    v_j := pg_temp.f252_read('DG', u_all, format('SELECT record_label_print(%L, %L, NULL, 1, %L)', 'inbound_batch', bq, NULL));
    IF (v_j #>> '{data,dg_missing}')::boolean IS DISTINCT FROM true THEN
        RAISE EXCEPTION 'FIXTURE 252 DG: a missing DG code must not refuse a print: %', v_j; END IF;
    v_msg := pg_temp.f252_try(u_all, format($q$UPDATE materials SET hs_code = '12345' WHERE id = %L$q$, m_bat));
    IF v_msg NOT LIKE '%materials_hs_code_shape%' THEN RAISE EXCEPTION 'FIXTURE 252 HS: five digits: %', v_msg; END IF;
    v_msg := pg_temp.f252_try(u_all, format($q$UPDATE materials SET hs_code = '1234567890123' WHERE id = %L$q$, m_bat));
    IF v_msg NOT LIKE '%materials_hs_code_shape%' THEN RAISE EXCEPTION 'FIXTURE 252 HS: thirteen digits: %', v_msg; END IF;
    v_msg := pg_temp.f252_try(u_all, format($q$UPDATE materials SET hs_code = '8549.ab' WHERE id = %L$q$, m_bat));
    IF v_msg NOT LIKE '%materials_hs_code_shape%' THEN RAISE EXCEPTION 'FIXTURE 252 HS: letters: %', v_msg; END IF;
    v_msg := pg_temp.f252_try(u_all, format($q$UPDATE materials SET hs_code = '854931.' WHERE id = %L$q$, m_bat));
    IF v_msg NOT LIKE '%materials_hs_code_shape%' THEN RAISE EXCEPTION 'FIXTURE 252 HS: a trailing dot: %', v_msg; END IF;
    v_msg := pg_temp.f252_try(u_all, format($q$UPDATE materials SET hs_code = '854931000000' WHERE id = %L$q$, m_bat));
    IF v_msg IS DISTINCT FROM 'OK' THEN RAISE EXCEPTION 'FIXTURE 252 HS: twelve digits should pass: %', v_msg; END IF;
    v_msg := pg_temp.f252_try(u_all, format($q$UPDATE materials SET hs_code = '8549.31.00', dg_code = 'UN3480' WHERE id = %L$q$, m_bm));
    IF v_msg IS DISTINCT FROM 'OK' THEN RAISE EXCEPTION 'FIXTURE 252 HS: 8549.31.00 with UN3480 should pass: %', v_msg; END IF;
    v_msg := pg_temp.f252_try(u_all, format($q$UPDATE materials SET dg_code = 'UN9999' WHERE id = %L$q$, m_bat));
    IF v_msg NOT LIKE '%materials_dg_code_fkey%' THEN RAISE EXCEPTION 'FIXTURE 252 DG: a code not in the dictionary: %', v_msg; END IF;

    -- ══════════════ SHIP · QUAR · DG on the shipping side ══════════════
    -- 产出批(黑粉,选了 UN3480)收进 L1;另一批开着鼓包或漏液(要隔离),放在普通库位 —— 记状态不拒,被标出来(MES-3a Q20)
    ob := (pg_temp.f252_read('SHIP', u_all, format('SELECT create_output_batch(%L, 100, %L, %L, %L, NULL, NULL, NULL, %L) -> %L',
                                                   m_bm, 'kg', d, '库存中', l1, 'batch_id'))) #>> '{}';
    SELECT code INTO ob_code FROM output_batches WHERE id = ob;
    ob2 := (pg_temp.f252_read('SHIP', u_all, format('SELECT create_output_batch(%L, 100, %L, %L, %L, NULL, NULL, NULL, %L) -> %L',
                                                    m_bm, 'kg', d, '库存中', l1, 'batch_id'))) #>> '{}';
    v_msg := pg_temp.f252_try(u_all, format('SELECT set_output_safety_states(%L, ARRAY[%L])', ob2, 'swollen_leaking'));
    IF v_msg IS DISTINCT FROM 'OK' THEN RAISE EXCEPTION 'FIXTURE 252 QUAR: setup — recording a state on placed stock: %', v_msg; END IF;

    INSERT INTO customers (code, legal_name, country, payment_terms_days, address)
    VALUES ('ZZ252-C', 'f252 customer', 'SG', 30, '252 Fixture Road') RETURNING id INTO v_x;
    INSERT INTO sales_orders (code, customer_id, order_date, currency, fx_rate)
    VALUES (next_sales_order_code(d), v_x, d, v_base, 1) RETURNING id INTO so;
    INSERT INTO sales_order_lines (sales_order_id, line_no, material_id, quantity, unit_price) VALUES (so, 1, m_bm, 10, 10) RETURNING id INTO sl1;
    INSERT INTO sales_order_lines (sales_order_id, line_no, material_id, quantity, unit_price) VALUES (so, 2, m_bm, 10, 10) RETURNING id INTO sl2;
    INSERT INTO sales_order_lines (sales_order_id, line_no, material_id, quantity, unit_price) VALUES (so, 3, m_bm, 10, 10) RETURNING id INTO sl3;
    PERFORM set_sales_order_status(so, 'confirmed');
    PERFORM create_order_invoice(so, d, NULL, NULL, NULL, ARRAY[sl1, sl2, sl3]);
    res1 := (reserve_stock(sl1, ob, 10, l1) ->> 'reservation_id')::uuid;
    res2 := (reserve_stock(sl2, ob, 10, l1) ->> 'reservation_id')::uuid;
    res3 := (reserve_stock(sl3, ob2, 10, l1) ->> 'reservation_id')::uuid;
    PERFORM submit_shipping_release(so);

    -- 发货队列:DG 编号、要隔离的状态(那一批)、仓库读得到
    v_j := pg_temp.f252_read('QUAR', u_wh, format($q$SELECT jsonb_agg(jsonb_build_object('b', output_batch_code, 'dg', dg_code, 'miss', dg_missing, 'q', quarantine_states)
                                                      ORDER BY line_no) FROM shipping_queue_rows() WHERE sales_order_id = %L$q$, so));
    IF v_j -> 0 ->> 'dg' IS DISTINCT FROM 'UN3480' OR (v_j -> 0 ->> 'miss')::boolean IS DISTINCT FROM false OR v_j -> 0 ->> 'q' IS NOT NULL
       OR v_j -> 2 ->> 'q' IS DISTINCT FROM 'swollen_leaking' THEN
        RAISE EXCEPTION 'FIXTURE 252 QUAR: the shipping queue should carry the DG code and flag the quarantine state on the third line: %', v_j; END IF;

    -- 发货:扫错 → SHIP_SCAN_MISMATCH,一行不发
    v_msg := pg_temp.f252_try(u_wh, format($q$SELECT ship_order(%L, %L, jsonb_build_array(jsonb_build_object('reservation_id', %L, 'scanned_code', %L)))$q$,
                                         so, d, res1, b_code));
    IF v_msg IS DISTINCT FROM 'SHIP_SCAN_MISMATCH|' || b_code || '|' || ob_code THEN
        RAISE EXCEPTION 'FIXTURE 252 SHIP: a mismatching scan: %', v_msg; END IF;
    IF EXISTS (SELECT 1 FROM shipments WHERE sales_order_id = so) THEN RAISE EXCEPTION 'FIXTURE 252 SHIP: a refused shipment left a shipment'; END IF;
    -- 扫对(小写也算)→ 发
    v_msg := pg_temp.f252_try(u_wh, format($q$SELECT ship_order(%L, %L, jsonb_build_array(jsonb_build_object('reservation_id', %L, 'scanned_code', %L)))$q$,
                                         so, d, res1, '  ' || lower(ob_code) || ' '));
    IF v_msg IS DISTINCT FROM 'OK' THEN RAISE EXCEPTION 'FIXTURE 252 SHIP: a matching scan was refused: %', v_msg; END IF;
    -- 不扫 → 照发;要隔离的那一批也照发(标,不拒)
    v_msg := pg_temp.f252_try(u_wh, format($q$SELECT ship_order(%L, %L, jsonb_build_array(jsonb_build_object('reservation_id', %L), jsonb_build_object('reservation_id', %L)))$q$,
                                         so, d, res2, res3));
    IF v_msg IS DISTINCT FROM 'OK' THEN RAISE EXCEPTION 'FIXTURE 252 SHIP: shipping without a scan (and a flagged batch) was refused: %', v_msg; END IF;
    IF (SELECT count(*) FROM shipment_lines sl JOIN shipments s ON s.id = sl.shipment_id WHERE s.sales_order_id = so) <> 3 THEN
        RAISE EXCEPTION 'FIXTURE 252 SHIP: expected three shipment lines'; END IF;

    -- 发货单:DG · HS · 要隔离的状态,仓库读得到
    v_j := pg_temp.f252_read('QUAR', u_wh, format($q$SELECT jsonb_agg(l ORDER BY l ->> 'line_no')
                                                     FROM shipments s, jsonb_array_elements(shipment_document(s.id) -> 'lines') l
                                                    WHERE s.sales_order_id = %L$q$, so));
    IF v_j -> 0 ->> 'dg_code' IS DISTINCT FROM 'UN3480' OR v_j -> 0 ->> 'dg_class' IS DISTINCT FROM '9' OR v_j -> 0 ->> 'hs_code' IS DISTINCT FROM '8549.31.00'
       OR (v_j -> 0 ->> 'dg_missing')::boolean IS DISTINCT FROM false OR v_j -> 0 ->> 'quarantine_states' IS NOT NULL
       OR v_j -> 2 ->> 'quarantine_states' IS DISTINCT FROM 'swollen_leaking' THEN
        RAISE EXCEPTION 'FIXTURE 252 QUAR: the shipment document lines should carry DG, HS and the quarantine flag: %', v_j; END IF;
    -- 没选编号的电池料:发货单行说 dg_missing(只提示)
    UPDATE materials SET dg_code = NULL WHERE id = m_bm;
    v_j := pg_temp.f252_read('DG', u_wh, format($q$SELECT jsonb_agg(l ->> 'dg_missing') FROM shipments s, jsonb_array_elements(shipment_document(s.id) -> 'lines') l
                                                   WHERE s.sales_order_id = %L$q$, so));
    IF v_j IS DISTINCT FROM '["true", "true", "true"]'::jsonb THEN
        RAISE EXCEPTION 'FIXTURE 252 DG: a battery material with no DG code should say dg_missing on every document line: %', v_j; END IF;

    -- ══════════════ PV · 给了就消失 ══════════════
    UPDATE dangerous_goods_codes SET marking_text = 'f252', packing_instruction = 'f252', label_size = 'f252' WHERE code = 'UN3480';
    UPDATE materials SET dg_code = 'UN3480', hs_code = '854931' WHERE id = m_bm;
    v_j := pg_temp.f252_read('PV', u_all, $q$SELECT jsonb_agg(value_code || ':' || item_code ORDER BY value_code, item_code) FROM pending_values
                                              WHERE value_code IN ('V30', 'V31', 'V35') AND (value_code = 'V30' OR item_code LIKE 'ZZ252%')$q$);
    IF v_j IS DISTINCT FROM '["V30:UN3090", "V30:UN3091", "V30:UN3481", "V35:ZZ252-BAT"]'::jsonb THEN
        RAISE EXCEPTION 'FIXTURE 252 PV: after supplying values the pending list should shrink: %', v_j; END IF;

    RAISE NOTICE 'FIXTURE 252 全部通过: PRINT · GATE · NAME · LINK · RESOLVE · LOG · MOVE · SHIP · DG · HS · QUAR · PV';
END;
$$;

ROLLBACK;

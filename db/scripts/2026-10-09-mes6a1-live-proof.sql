-- db/scripts/2026-10-09-mes6a1-live-proof.sql
-- MES-6a-1 · 线上的证明 —— 【一笔事务,以 ROLLBACK 收尾】:什么都不留。审批开着,一处都不关;审批的设定一个字都不改。
--   由 db/scripts/2026-10-09-mes6a1-live-proof.mjs 驱动:它先用 mintThrowaway 造一次性账号(前缀 mes6a1probe),
--   再以 psql 跑本文件,把那些邮箱经 -v 传进来;跑完按 ephemeral 计划收走账号、授权、一次性角色。
--   【每一个动作都以一次性账号跑】(七个真账号一个都不用):
--     qe   = module.quality.view/edit + inbound/output.view        —— 取样、记保管、立 / 记仲裁 / 撤回争议、挂仲裁费
--     rec  = module.inbound/output.view + .edit                    —— 记化验(含"化验的是哪份样品")
--     apl  = inbound/output/quality.view + action.apply_assay + data.view_purchase_prices + data.view_prices —— 应用、试算、结案
--     cfo  = 真的 cfo 角色本身(realRole)—— 只为【决定】那张化验定价申请(二级审批人认的是角色);不是建单人
--     dict = module.materials.view/edit                            —— 字典编辑器里把实验室指到供应商
--     fin  = module.finance.view/edit + module.suppliers.view      —— 记费用单、冲销
--     sal  = module.customers.view/edit + module.output.view + module.pricing.view —— 把销售单挂到合同、算卖方结算(行情要定价查看码)
--     c_<角色> = 七个真角色【此刻的码】的一次性克隆(cloneOf)—— 只读:逐角色读数表;对账在 c_cfo 的会话里读
--   【布景】(以属主插,都是我自己的行,前缀 ZZ-PROBE-MES6A1):两家供应商(货 · 仲裁实验室那一户)、一种物料、两家实验室、一批进料、
--     一批产出、一张购买公式与它的承诺、今天的 USD 牌价与 ni 行情、LME 九月的日历与行情、一个客户、一份合同(容差 0.5 · 仲裁费各半)、
--     一张销售单。线上原本【没有】今天的 USD 牌价与 ni 行情(读过:0 行)—— 所以这里插自己的,随回滚消失。
--   ① 样品:qe 取一份我们的样品(进料批),送实验室 → 拿回来;rec 记一份化验注明是这份样品;拿别的批的样品 → SAMPLE_NOT_FOR_BATCH。
--   ② 买方争议:apl 应用我们的化验 → 一张化验定价申请在等 CFO;qe 立争议;apl 应用对手方的 / 试算 → 同一句 ASSAY_DISPUTE_OPEN;
--      cfo 批那张申请 → ASSAY_DISPUTE_OPEN,什么都不落;记仲裁样品与结果;apl 结案点名仲裁的那一份 → 批次状态逐字未变(什么都不应用);
--      之后 cfo 批得下来(过账)。
--   ③ 卖方争议:销售单挂合同;结算先算一次;qe 立争议(抄进容差 0.5 与各半)→ 结算按名拒;撤回 → 结算的结果与之前一模一样。
--   ④ 仲裁费:dict 把仲裁实验室指到它那一户;fin 记一张未付费用单给那一户;qe 挂到买方那件争议上。
--   ⑤ 冲销:fin 记一张费用单;不给理由 / 空白 → EXPENSE_REVERSAL_REASON_REQUIRED|单号;给理由 → 理由写在原单上,镜像单 notes 只剩机器字。
--   ⑥ 逐角色读数表(只读):样品页 / 争议页进得去吗、取样 / 立争议 / 结案按得下去吗、批次页的质量面板读到几行、费用页进得去吗、
--      冲销按得下去吗、仲裁费金额读得到还是受限、V16 改得动吗、实验室的供应商改得动吗。
--   每一个碰到钱的步骤之后:AP / AR 清单 = 总账,两边 unexplained 0.00(c_cfo 的会话)。在册的东西一张都不碰、不决定、不改。
-- 打印的每一行都是 STEP|… 或 ROLE|… ;任何一处与预期不符就 RAISE,整笔回滚。
\pset pager off
\pset format unaligned
\pset tuples_only on
BEGIN;
SET LOCAL statement_timeout = '300s';
SELECT set_config('mes6a1.qe', :'qe', true), set_config('mes6a1.rec', :'rec', true), set_config('mes6a1.apl', :'apl', true),
       set_config('mes6a1.cfo', :'cfo', true), set_config('mes6a1.dict', :'dict', true), set_config('mes6a1.fin', :'fin', true),
       set_config('mes6a1.sal', :'sal', true),
       set_config('mes6a1.c_admin', :'c_admin', true), set_config('mes6a1.c_finance', :'c_finance', true),
       set_config('mes6a1.c_warehouse', :'c_warehouse', true), set_config('mes6a1.c_cto', :'c_cto', true),
       set_config('mes6a1.c_cco', :'c_cco', true), set_config('mes6a1.c_cfo', :'c_cfo', true), set_config('mes6a1.c_gm', :'c_gm', true) \g /dev/null

CREATE FUNCTION pg_temp.as_(p_who text) RETURNS void LANGUAGE plpgsql AS $f$
DECLARE v uuid; e text := current_setting('mes6a1.' || p_who);
BEGIN
    EXECUTE 'RESET ROLE';
    SELECT id INTO v FROM auth.users WHERE email = e;
    IF v IS NULL OR e NOT LIKE 'mes6a1probe-%@test.local' THEN RAISE EXCEPTION 'MES6A1_LIVE|not a throwaway account: % (%)', p_who, e; END IF;
    PERFORM set_config('request.jwt.claims', format('{"sub":"%s","role":"authenticated"}', v), true);
    EXECUTE 'SET LOCAL ROLE authenticated';
END $f$;
CREATE FUNCTION pg_temp.me_() RETURNS void LANGUAGE plpgsql AS $f$
BEGIN
    EXECUTE 'RESET ROLE';
    PERFORM set_config('request.jwt.claims', '', true);
END $f$;
CREATE FUNCTION pg_temp.try_(p_sql text) RETURNS text LANGUAGE plpgsql AS $f$
BEGIN
    EXECUTE p_sql;
    RETURN 'OK';
EXCEPTION WHEN OTHERS THEN
    RETURN SQLERRM;
END $f$;
CREATE FUNCTION pg_temp.agree_(p_step text) RETURNS text LANGUAGE plpgsql AS $f$
DECLARE v jsonb; s jsonb; out text := '';
BEGIN
    PERFORM pg_temp.as_('c_cfo');
    v := list_ledger_reconciliation();
    PERFORM pg_temp.me_();
    FOR s IN SELECT * FROM jsonb_array_elements(v -> 'sides') LOOP
        IF s ->> 'refusal' IS NOT NULL OR (s ->> 'unexplained_base')::numeric IS DISTINCT FROM 0 THEN
            RAISE EXCEPTION 'MES6A1_LIVE|AP/AR list <> ledger after %: % list % ledger % unexplained %', p_step, s ->> 'side', s ->> 'list_base', s ->> 'ledger_base', s ->> 'unexplained_base';
        END IF;
        out := out || (s ->> 'side') || ' ' || (s ->> 'list_base') || ' / ' || (s ->> 'ledger_base') || ' / ' || (s ->> 'unexplained_base') || '; ';
    END LOOP;
    RETURN out;
END $f$;
-- 一批的状态指纹:含量、化验的应用与取代、定价申请、单价、定价状态、总账的分录数
CREATE FUNCTION pg_temp.state_(p_batch uuid) RETURNS text LANGUAGE sql AS $f$
    SELECT md5(concat_ws('|',
        (SELECT string_agg(metal || ':' || content_pct || ':' || COALESCE(source_assay_id::text, '-'), ',' ORDER BY metal) FROM inbound_batch_metals WHERE inbound_batch_id = p_batch),
        (SELECT string_agg(code || ':' || (applied_at IS NOT NULL) || ':' || COALESCE(superseded_by::text, '-'), ',' ORDER BY code) FROM assay_results WHERE inbound_batch_id = p_batch),
        (SELECT string_agg(label || ':' || status, ',' ORDER BY label) FROM receipt_price_requests WHERE inbound_batch_id = p_batch),
        (SELECT COALESCE(unit_price::text, '-') || ':' || pricing_status FROM inbound_batches WHERE id = p_batch),
        (SELECT count(*)::text FROM journal_entries)))
$f$;
GRANT EXECUTE ON FUNCTION pg_temp.as_(text), pg_temp.me_(), pg_temp.try_(text) TO authenticated;

CREATE TEMP TABLE mes6a1_roles (who text, role text, codes integer, samples_page boolean, disputes_page boolean, can_record boolean,
    can_resolve boolean, panel_samples bigint, panel_disputes bigint, expense_page boolean, can_reverse boolean, fee text,
    v16_edit boolean, lab_supplier_edit boolean) ON COMMIT DROP;
GRANT INSERT ON mes6a1_roles TO authenticated;

DO $live$
DECLARE
    today date := (now() AT TIME ZONE 'Asia/Singapore')::date;
    v_base text := (SELECT code FROM currencies WHERE is_base);
    sup uuid; lab_sup uuid; mat uuid; b1 uuid; ob uuid; frm uuid; cust uuid; con uuid; so uuid;
    s1 uuid; s2 uuid; s_ob uuid; a1 uuid; c1 uuid; u1 uuid; oa uuid; oc uuid; q1 uuid; d1 uuid; dS uuid; e_fee uuid; e2 uuid; mirror uuid;
    v_msg text; v_msg2 text; v_j jsonb; v_rec text; v_txt text; v_before text; v_je0 bigint; v_settle_before text; v_settle_after text;
    v_pending text := (SELECT COALESCE(string_agg(subject_type || ':' || code, ',' ORDER BY code), '') FROM approval_pending_documents());
    v_fp_before text;
    v_t0 timestamptz := now();
    v_m30 jsonb := '[{"metal":"ni","content_pct":30}]';
    v_m33 jsonb := '[{"metal":"ni","content_pct":33}]';
    r record;
BEGIN
    -- 在册的东西先记一个指纹(我的行 created_at = 事务开始时刻 = v_t0,比较时按 < v_t0 排除)
    SELECT md5(concat_ws('#',
        (SELECT md5(string_agg(to_jsonb(x)::text, '|' ORDER BY x.id)) FROM inbound_batches x WHERE x.created_at < v_t0),
        (SELECT md5(string_agg(to_jsonb(x)::text, '|' ORDER BY x.id)) FROM output_batches x WHERE x.created_at < v_t0),
        (SELECT md5(string_agg(to_jsonb(x)::text, '|' ORDER BY x.inbound_batch_id, x.metal)) FROM inbound_batch_metals x WHERE x.created_at < v_t0),
        (SELECT md5(string_agg(to_jsonb(x)::text, '|' ORDER BY x.output_batch_id, x.metal)) FROM output_batch_metals x WHERE x.created_at < v_t0),
        (SELECT md5(string_agg(to_jsonb(x)::text, '|' ORDER BY x.id)) FROM assay_results x WHERE x.created_at < v_t0),
        (SELECT md5(string_agg(to_jsonb(x)::text, '|' ORDER BY x.id)) FROM receipt_price_requests x WHERE x.created_at < v_t0),
        (SELECT md5(string_agg(to_jsonb(x)::text, '|' ORDER BY x.id)) FROM contracts x WHERE x.created_at < v_t0),
        (SELECT md5(string_agg(to_jsonb(x)::text, '|' ORDER BY x.id)) FROM contract_settlement_terms x WHERE x.created_at < v_t0),
        (SELECT md5(string_agg(to_jsonb(x)::text, '|' ORDER BY x.id)) FROM sales_orders x WHERE x.created_at < v_t0),
        (SELECT md5(string_agg(to_jsonb(x)::text, '|' ORDER BY x.id)) FROM expenses x WHERE x.created_at < v_t0),
        (SELECT md5(string_agg(to_jsonb(x)::text, '|' ORDER BY x.id)) FROM payments x WHERE x.created_at < v_t0),
        (SELECT md5(string_agg(to_jsonb(x)::text, '|' ORDER BY x.id)) FROM journal_entries x WHERE x.created_at < v_t0),
        (SELECT md5(string_agg(to_jsonb(x)::text, '|' ORDER BY x.id)) FROM journal_lines x WHERE x.created_at < v_t0),
        (SELECT md5(string_agg(to_jsonb(x)::text, '|' ORDER BY x.code)) FROM laboratories x),
        (SELECT md5(string_agg(to_jsonb(x)::text, '|' ORDER BY x.id)) FROM suppliers x WHERE x.created_at < v_t0),
        (SELECT md5(string_agg(to_jsonb(x)::text, '|' ORDER BY x.id)) FROM fx_rates x WHERE x.created_at < v_t0),
        (SELECT md5(string_agg(to_jsonb(x)::text, '|' ORDER BY x.id)) FROM metal_prices x WHERE x.created_at < v_t0),
        (SELECT md5(to_jsonb(x)::text) FROM finance_settings x),
        (SELECT md5(to_jsonb(x)::text) FROM quality_settings x)))
      INTO v_fp_before;
    v_rec := pg_temp.agree_('start');
    RAISE NOTICE 'STEP|start|%', v_rec;
    IF EXISTS (SELECT 1 FROM samples) OR EXISTS (SELECT 1 FROM assay_disputes) THEN RAISE EXCEPTION 'MES6A1_LIVE|live already has a sample or a dispute — this proof expects none'; END IF;
    IF NOT approvals_enabled() THEN RAISE EXCEPTION 'MES6A1_LIVE|approvals are off on live'; END IF;

    -- ══ 布景(属主) ══
    -- 线上已登记 GST:一张费用单要一个进项税码(TAX_CODE_REQUIRED|supplier)—— 两户自己的供应商带默认码 OP(范围外采购,无税额),
    --   于是费用单照常从往来对象取码,AP 清单与总账之间没有税那一腿要对
    INSERT INTO suppliers (code, legal_name, country, status, counterparty_type, default_tax_code)
    VALUES ('ZZ-PROBE-MES6A1-S', 'ZZ-PROBE-MES6A1 goods supplier', 'SG', 'active', 'goods_supplier', 'OP') RETURNING id INTO sup;
    INSERT INTO suppliers (code, legal_name, country, status, counterparty_type, default_tax_code)
    VALUES ('ZZ-PROBE-MES6A1-LABS', 'ZZ-PROBE-MES6A1 umpire lab ltd', 'SG', 'active', 'service_vendor', 'OP') RETURNING id INTO lab_sup;
    INSERT INTO materials (code, name, kind_code, may_be_processed, form_code, source_code)
    VALUES ('ZZ-PROBE-MES6A1-BM', 'ZZ-PROBE-MES6A1 black mass', 'battery_material', true, 'black_mass', 'end_of_life') RETURNING id INTO mat;
    INSERT INTO laboratories (code, name_en, name_zh, is_active, sort_order) VALUES
        ('ZZ-PROBE-MES6A1-OURS', 'ZZ-PROBE-MES6A1 our lab', 'ZZ-PROBE-MES6A1 我方', true, 990),
        ('ZZ-PROBE-MES6A1-UMP', 'ZZ-PROBE-MES6A1 umpire lab', 'ZZ-PROBE-MES6A1 仲裁', true, 991);
    INSERT INTO inbound_batches (material_id, supplier_id, quantity, remaining_qty, unit, arrival_date, source_reason_code, source_reason_note)
    VALUES (mat, sup, 100, 100, 'kg', today - 3, 'other', 'ZZ-PROBE-MES6A1 live proof') RETURNING id INTO b1;
    INSERT INTO output_batches (material_id, quantity, remaining_qty, unit, output_date, notes)
    VALUES (mat, 10000, 10000, 'kg', DATE '2026-09-14', 'ZZ-PROBE-MES6A1 live proof') RETURNING id INTO ob;
    INSERT INTO fx_rates (currency, rate_date, rate_type, rate_sgd_per_unit) VALUES ('USD', today, 'tt_sell', 1.26);
    INSERT INTO metal_prices (metal, price_date, price_usd_per_tonne, source) VALUES ('ni', today, 15000, 'broker_quote');
    INSERT INTO pricing_formulas (code, name, direction, price_basis, treatment_charge_usd_per_tonne, flat_discount_pct, is_active)
    VALUES ('', 'ZZ-PROBE-MES6A1 formula', 'purchase', 'spot', 200, 0, true) RETURNING id INTO frm;
    INSERT INTO pricing_formula_metals (formula_id, metal, payable_pct) VALUES (frm, 'ni', 70);
    PERFORM commit_pricing_terms(frm, NULL, b1);
    RAISE NOTICE 'STEP|setup|inbound % (100 kg, formula committed) · output % · own USD rate and ni quote for % (live had none)',
        (SELECT code FROM inbound_batches WHERE id = b1), (SELECT code FROM output_batches WHERE id = ob), today;

    -- ══ ① 样品:取、送实验室、拿回来、注明在化验上 ══
    PERFORM pg_temp.as_('qe');
    s1 := (record_sample('ours', today - 2, p_inbound_batch_id => b1, p_mass_g => 200, p_notes => 'ZZ-PROBE-MES6A1') ->> 'sample_id')::uuid;
    PERFORM record_sample_event(s1, 'sent_to_lab', now() - interval '1 day', 'ZZ-PROBE-MES6A1-OURS', 'LAB-REF-1');
    v_j := (SELECT to_jsonb(x) FROM (SELECT state, laboratory_code, lab_reference FROM sample_rows WHERE id = s1) x);
    PERFORM record_sample_event(s1, 'received_back', now() - interval '2 hours');
    s_ob := (record_sample('ours', DATE '2026-09-15', p_output_batch_id => ob) ->> 'sample_id')::uuid;
    PERFORM pg_temp.me_();
    IF v_j <> '{"state":"at_lab","laboratory_code":"ZZ-PROBE-MES6A1-OURS","lab_reference":"LAB-REF-1"}'::jsonb
       OR (SELECT state || ':' || event_count || ':' || retain_until_source FROM sample_rows WHERE id = s1) <> 'held:3:not_set' THEN
        RAISE EXCEPTION 'MES6A1_LIVE|custody: at lab % · now %', v_j, (SELECT state || ':' || event_count || ':' || retain_until_source FROM sample_rows WHERE id = s1);
    END IF;
    PERFORM pg_temp.as_('rec');
    a1 := (record_assay_result(p_assay_date => today, p_metals => v_m30, p_lab_name => 'ZZ-PROBE-MES6A1-OURS', p_inbound_batch_id => b1,
                               p_weight_basis => 'as_received', p_result_party => 'ours', p_sample_id => s1) ->> 'assay_result_id')::uuid;
    c1 := (record_assay_result(p_assay_date => today, p_metals => v_m33, p_inbound_batch_id => b1,
                               p_weight_basis => 'as_received', p_result_party => 'counterparty') ->> 'assay_result_id')::uuid;
    v_msg := pg_temp.try_(format($q$SELECT record_assay_result(p_assay_date => CURRENT_DATE, p_metals => '[{"metal":"ni","content_pct":31}]'::jsonb,
        p_inbound_batch_id => %L, p_weight_basis => 'as_received', p_result_party => 'ours', p_sample_id => %L)$q$, b1, s_ob));
    PERFORM pg_temp.me_();
    IF (SELECT sample_id FROM assay_results WHERE id = a1) IS DISTINCT FROM s1 OR v_msg NOT LIKE 'SAMPLE_NOT_FOR_BATCH|%' THEN
        RAISE EXCEPTION 'MES6A1_LIVE|assay ↔ sample: %', v_msg;
    END IF;
    RAISE NOTICE 'STEP|sample|qe took % (ours, 200 g, keep-until Not yet set — V16 is empty) · sent to ZZ-PROBE-MES6A1-OURS (LAB-REF-1, state at_lab) · received back (state held, 3 custody lines) · rec recorded % naming it · a sample from another batch refused (%)',
        (SELECT code FROM samples WHERE id = s1), (SELECT code FROM assay_results WHERE id = a1), split_part(v_msg, '|', 1);

    -- ══ ② 买方争议:挡住应用、试算与化验定价的过账;结案什么都不应用 ══
    PERFORM pg_temp.as_('apl');
    v_j := apply_assay_result(a1);
    PERFORM pg_temp.me_();
    q1 := (v_j -> 'price_request' ->> 'request_id')::uuid;
    IF (v_j -> 'price_request' ->> 'status') IS DISTINCT FROM 'submitted' THEN RAISE EXCEPTION 'MES6A1_LIVE|the assay request should wait for the CFO: %', v_j; END IF;
    v_rec := pg_temp.agree_('assay applied (request waiting)');
    PERFORM pg_temp.as_('qe');
    v_j := open_assay_dispute(a1, c1, 'ZZ-PROBE-MES6A1: their nickel is 3 points higher');
    PERFORM pg_temp.me_();
    d1 := (v_j ->> 'dispute_id')::uuid;
    IF (v_j ->> 'limit_pct_at') IS NOT NULL OR (v_j ->> 'fee_rule_at') IS NOT NULL THEN RAISE EXCEPTION 'MES6A1_LIVE|buy-side dispute snapshot: %', v_j; END IF;
    PERFORM pg_temp.as_('apl');
    v_msg := pg_temp.try_(format('SELECT apply_assay_result(%L)', c1));
    v_msg2 := pg_temp.try_(format($q$SELECT preview_assay_price(%L, %L::jsonb, CURRENT_DATE)$q$, b1, v_m33));
    PERFORM pg_temp.me_();
    IF v_msg NOT LIKE format('ASSAY_DISPUTE_OPEN|%s|%s', (SELECT code FROM inbound_batches WHERE id = b1), d1) OR v_msg <> v_msg2 THEN
        RAISE EXCEPTION 'MES6A1_LIVE|apply «%» / preview «%»', v_msg, v_msg2;
    END IF;
    RAISE NOTICE 'STEP|dispute held|qe opened a dispute on % (limit not set, no fee rule — buy side) · apl applying the counterparty result and previewing its price both refused with the same «%»',
        (SELECT code FROM inbound_batches WHERE id = b1), v_msg;
    v_je0 := (SELECT count(*) FROM journal_entries);
    PERFORM pg_temp.as_('cfo');
    v_msg := pg_temp.try_(format('SELECT decide_receipt_price_request(%L, true)', q1));
    PERFORM pg_temp.me_();
    IF v_msg NOT LIKE 'ASSAY_DISPUTE_OPEN|%' OR (SELECT status FROM receipt_price_requests WHERE id = q1) <> 'submitted'
       OR (SELECT count(*) FROM journal_entries) <> v_je0 OR (SELECT unit_price FROM inbound_batches WHERE id = b1) IS NOT NULL THEN
        RAISE EXCEPTION 'MES6A1_LIVE|posting the waiting assay request: % (status %)', v_msg, (SELECT status FROM receipt_price_requests WHERE id = q1);
    END IF;
    RAISE NOTICE 'STEP|posting refused|the CFO approving % refused «%» — still submitted, no journal, no price', (SELECT label FROM receipt_price_requests WHERE id = q1), v_msg;
    v_rec := pg_temp.agree_('posting refused');
    -- 仲裁:样品与结果
    PERFORM pg_temp.as_('qe');
    s2 := (record_sample('umpire', today - 1, p_inbound_batch_id => b1) ->> 'sample_id')::uuid;
    PERFORM pg_temp.as_('rec');
    u1 := (record_assay_result(p_assay_date => today, p_metals => v_m33, p_lab_name => 'ZZ-PROBE-MES6A1-UMP', p_inbound_batch_id => b1,
                               p_weight_basis => 'as_received', p_result_party => 'umpire', p_sample_id => s2) ->> 'assay_result_id')::uuid;
    PERFORM pg_temp.as_('qe');
    PERFORM record_dispute_umpire(d1, s2, u1);
    v_msg := pg_temp.try_(format($q$SELECT resolve_assay_dispute(%L, %L, 'quality edit is not enough')$q$, d1, u1));
    PERFORM pg_temp.me_();
    IF v_msg NOT LIKE 'PERMISSION_DENIED|action.apply_assay%' THEN RAISE EXCEPTION 'MES6A1_LIVE|resolve by qe: %', v_msg; END IF;
    v_before := pg_temp.state_(b1);
    PERFORM pg_temp.as_('apl');
    PERFORM resolve_assay_dispute(d1, u1, 'ZZ-PROBE-MES6A1: the umpire result governs');
    PERFORM pg_temp.me_();
    IF pg_temp.state_(b1) <> v_before OR (SELECT applied_at FROM assay_results WHERE id = u1) IS NOT NULL
       OR (SELECT status || ':' || governing_assay_id FROM assay_disputes WHERE id = d1) <> 'resolved:' || u1 THEN
        RAISE EXCEPTION 'MES6A1_LIVE|resolving applied something';
    END IF;
    RAISE NOTICE 'STEP|resolved|umpire sample % and result % recorded · qe could not resolve (%) · apl resolved naming % — content, applications, requests, price and the journal count identical (nothing applied)',
        (SELECT code FROM samples WHERE id = s2), (SELECT code FROM assay_results WHERE id = u1), split_part(v_msg, '|', 1) || '|' || split_part(v_msg, '|', 2),
        (SELECT code FROM assay_results WHERE id = u1);
    PERFORM pg_temp.as_('cfo');
    PERFORM decide_receipt_price_request(q1, true);
    PERFORM pg_temp.me_();
    IF (SELECT status FROM receipt_price_requests WHERE id = q1) <> 'approved' THEN RAISE EXCEPTION 'MES6A1_LIVE|the held request did not post after resolution'; END IF;
    v_rec := pg_temp.agree_('held request posted');
    RAISE NOTICE 'STEP|hold lifted|the CFO approved % after the resolution (unit price % %) · reconciliation %',
        (SELECT label FROM receipt_price_requests WHERE id = q1), (SELECT unit_price FROM inbound_batches WHERE id = b1), v_base, v_rec;

    -- ══ ③ 卖方争议挡住结算 ══
    INSERT INTO index_market_calendar (index_code, calendar_date, is_trading_day, note)
    SELECT 'LME', g::date, EXTRACT(ISODOW FROM g) < 6, 'ZZ-PROBE-MES6A1'
      FROM generate_series(DATE '2026-09-01', DATE '2026-09-30', interval '1 day') g
    ON CONFLICT DO NOTHING;
    INSERT INTO metal_prices (metal, price_usd_per_tonne, price_date, source, price_index)
    SELECT 'ni', 10000, c.calendar_date, 'published_index', 'LME'
      FROM index_market_calendar c WHERE c.index_code = 'LME' AND c.is_trading_day AND c.calendar_date BETWEEN DATE '2026-09-01' AND DATE '2026-09-30'
    ON CONFLICT DO NOTHING;
    INSERT INTO customers (code, legal_name, country, payment_terms_days) VALUES ('ZZ-PROBE-MES6A1-C', 'ZZ-PROBE-MES6A1 customer', 'SG', 30) RETURNING id INTO cust;
    INSERT INTO contracts (customer_id, kind, title, effective_from, status)
    VALUES (cust, 'offtake', 'ZZ-PROBE-MES6A1 offtake', DATE '2026-01-01', 'active') RETURNING id INTO con;
    INSERT INTO contract_pricing_terms (contract_id, metal, base_event, qp_months, index_code, payable_pct) VALUES (con, 'ni', 'assay_complete', 0, 'LME', 70);
    INSERT INTO contract_settlement_terms (contract_id, sale_weight_basis, settling_party, splitting_limit_pct, sample_retention_required,
                                           refining_charge_basis, penalty_basis, arbitration_fee_rule)
    VALUES (con, 'dry', 'ours', 0.5, false, 'none_agreed', 'none_agreed', 'equal');
    INSERT INTO sales_orders (code, customer_id, order_date, currency, fx_rate)
    VALUES ('ZZ-PROBE-MES6A1-SO', cust, DATE '2026-06-10', v_base, 1) RETURNING id INTO so;
    PERFORM pg_temp.as_('sal');
    PERFORM link_document_to_contract('sales_order', so, con);
    PERFORM pg_temp.as_('rec');
    oa := (record_assay_result(p_assay_date => DATE '2026-09-15', p_metals => '[{"metal":"ni","content_pct":20}]'::jsonb, p_output_batch_id => ob,
                               p_weight_basis => 'dry', p_moisture_pct => 10, p_result_party => 'ours', p_sample_id => s_ob) ->> 'assay_result_id')::uuid;
    oc := (record_assay_result(p_assay_date => DATE '2026-09-15', p_metals => '[{"metal":"ni","content_pct":20.3}]'::jsonb, p_output_batch_id => ob,
                               p_weight_basis => 'dry', p_moisture_pct => 10, p_result_party => 'counterparty') ->> 'assay_result_id')::uuid;
    PERFORM pg_temp.as_('sal');
    v_settle_before := pg_temp.try_(format('SELECT sale_settlement_compute(%L, %L, %L)', so, ob, oa));
    IF v_settle_before = 'OK' THEN v_settle_before := (SELECT sale_settlement_compute(so, ob, oa))::text; END IF;
    PERFORM pg_temp.as_('qe');
    v_j := open_assay_dispute(oa, oc, 'ZZ-PROBE-MES6A1: the buyer contests nickel', so);
    dS := (v_j ->> 'dispute_id')::uuid;
    PERFORM pg_temp.as_('sal');
    v_msg := pg_temp.try_(format('SELECT sale_settlement_compute(%L, %L, %L)', so, ob, oa));
    PERFORM pg_temp.as_('qe');
    PERFORM withdraw_assay_dispute(dS, 'ZZ-PROBE-MES6A1: agreed at our figure');
    PERFORM pg_temp.as_('sal');
    v_settle_after := pg_temp.try_(format('SELECT sale_settlement_compute(%L, %L, %L)', so, ob, oa));
    IF v_settle_after = 'OK' THEN v_settle_after := (SELECT sale_settlement_compute(so, ob, oa))::text; END IF;
    PERFORM pg_temp.me_();
    IF (v_j ->> 'limit_pct_at')::numeric IS DISTINCT FROM 0.5 OR (v_j ->> 'fee_rule_at') IS DISTINCT FROM 'equal'
       OR v_msg NOT LIKE format('ASSAY_DISPUTE_OPEN|%s|%s', (SELECT code FROM output_batches WHERE id = ob), dS)
       OR v_settle_after IS DISTINCT FROM v_settle_before THEN
        RAISE EXCEPTION 'MES6A1_LIVE|sell side: snapshot % · during «%» · before «%» · after «%»', v_j, v_msg, left(v_settle_before, 200), left(v_settle_after, 200);
    END IF;
    RAISE NOTICE 'STEP|sell side|% linked to % (limit 0.5 · fee split equally) · settlement before: «%» · qe opened a dispute (limit and rule copied in) → settlement refused «%» · withdrawn → settlement identical to before',
        (SELECT code FROM sales_orders WHERE id = so), (SELECT code FROM contracts WHERE id = con), left(v_settle_before, 160), v_msg;

    -- ══ ④ 仲裁费:实验室指到它那一户,费用单付给那一户 ══
    PERFORM pg_temp.as_('qe');
    v_msg := pg_temp.try_(format($q$UPDATE laboratories SET supplier_id = %L WHERE code = 'ZZ-PROBE-MES6A1-UMP'$q$, lab_sup));
    PERFORM pg_temp.as_('dict');
    v_msg2 := pg_temp.try_(format($q$UPDATE laboratories SET supplier_id = %L WHERE code = 'ZZ-PROBE-MES6A1-UMP'$q$, lab_sup));
    PERFORM pg_temp.me_();
    IF v_msg NOT LIKE 'PERMISSION_DENIED|module.materials.edit%' OR v_msg2 <> 'OK'
       OR (SELECT supplier_id FROM laboratories WHERE code = 'ZZ-PROBE-MES6A1-UMP') IS DISTINCT FROM lab_sup THEN
        RAISE EXCEPTION 'MES6A1_LIVE|lab → supplier: qe «%» dict «%»', v_msg, v_msg2;
    END IF;
    PERFORM pg_temp.as_('fin');
    e_fee := (record_expense(today, '6400', 850, v_base, p_supplier_id => lab_sup, p_notes => 'ZZ-PROBE-MES6A1 umpire assay fee') ->> 'expense_id')::uuid;
    PERFORM pg_temp.me_();
    v_rec := pg_temp.agree_('fee expense recorded');
    PERFORM pg_temp.as_('qe');
    PERFORM link_dispute_fee(d1, e_fee);
    PERFORM pg_temp.me_();
    IF (SELECT fee_expense_id FROM assay_disputes WHERE id = d1) IS DISTINCT FROM e_fee
       OR (SELECT payment_status || ':' || status FROM expenses WHERE id = e_fee) <> 'unpaid:posted' THEN
        RAISE EXCEPTION 'MES6A1_LIVE|fee not linked';
    END IF;
    RAISE NOTICE 'STEP|fee|qe could not link the lab (%) · dict linked ZZ-PROBE-MES6A1-UMP to ZZ-PROBE-MES6A1-LABS · fin recorded % (850.00 %, unpaid, to the lab''s supplier) · qe linked it to the dispute · reconciliation %',
        split_part(v_msg, '|', 1) || '|' || split_part(v_msg, '|', 2), (SELECT code FROM expenses WHERE id = e_fee), v_base, v_rec;

    -- ══ ⑤ 冲销要一句理由 ══
    PERFORM pg_temp.as_('fin');
    e2 := (record_expense(today, '6400', 120, v_base, p_supplier_id => sup, p_notes => 'ZZ-PROBE-MES6A1 entered twice') ->> 'expense_id')::uuid;
    v_msg := pg_temp.try_(format('SELECT reverse_expense(%L)', e2));
    v_msg2 := pg_temp.try_(format($q$SELECT reverse_expense(%L, '   ')$q$, e2));
    PERFORM pg_temp.me_();
    IF v_msg NOT LIKE 'EXPENSE_REVERSAL_REASON_REQUIRED|' || (SELECT code FROM expenses WHERE id = e2) || '%' OR v_msg2 <> v_msg
       OR (SELECT status FROM expenses WHERE id = e2) <> 'posted' THEN
        RAISE EXCEPTION 'MES6A1_LIVE|blank reason: «%» / «%»', v_msg, v_msg2;
    END IF;
    v_rec := pg_temp.agree_('reversal refused');
    PERFORM pg_temp.as_('fin');
    PERFORM reverse_expense(e2, '  ZZ-PROBE-MES6A1: same invoice already entered  ');
    PERFORM pg_temp.me_();
    SELECT reversed_by_expense INTO mirror FROM expenses WHERE id = e2;
    IF (SELECT status || '|' || reversal_reason || '|' || (reversed_by IS NOT NULL) FROM expenses WHERE id = e2)
         <> 'reversed|ZZ-PROBE-MES6A1: same invoice already entered|true'
       OR (SELECT notes FROM expenses WHERE id = mirror) <> 'REVERSAL: ' || (SELECT code FROM expenses WHERE id = e2) THEN
        RAISE EXCEPTION 'MES6A1_LIVE|reversal with reason: %', (SELECT to_jsonb(x) FROM (SELECT status, reversal_reason, reversed_by FROM expenses WHERE id = e2) x);
    END IF;
    v_rec := pg_temp.agree_('reversed with a reason');
    RAISE NOTICE 'STEP|reversal|% · no reason and a blank reason both refused «%» · reversed with a reason → stored (trimmed) on the original, who and when beside it; mirror % notes «REVERSAL: %» · reconciliation %',
        (SELECT code FROM expenses WHERE id = e2), v_msg, (SELECT code FROM expenses WHERE id = mirror), (SELECT code FROM expenses WHERE id = e2), v_rec;

    -- ══ ⑥ 逐角色读数表(只读)══
    FOR r IN SELECT unnest(ARRAY['c_admin', 'c_finance', 'c_warehouse', 'c_cto', 'c_cco', 'c_cfo', 'c_gm']) AS who LOOP
        PERFORM pg_temp.as_(r.who);
        INSERT INTO mes6a1_roles
        SELECT r.who, (SELECT ro.code FROM user_roles ur JOIN roles ro ON ro.id = ur.role_id WHERE ur.user_id = auth.uid() LIMIT 1),
               cardinality(current_user_permissions()),
               has_permission('module.quality.view'), has_permission('module.quality.view'),
               has_permission('module.quality.edit'), has_permission('action.apply_assay'),
               (SELECT count(*) FROM sample_rows WHERE inbound_batch_id = b1),
               (SELECT count(*) FROM assay_dispute_rows WHERE inbound_batch_id = b1),
               has_permission('module.finance.view'), has_permission('module.finance.edit'),
               (SELECT CASE WHEN fee_restricted THEN 'restricted' WHEN fee_amount_base IS NULL THEN 'no row' ELSE fee_amount_base::text END
                  FROM assay_dispute_rows WHERE id = d1),
               has_permission('module.quality.edit'), has_permission('module.materials.edit');
        PERFORM pg_temp.me_();
    END LOOP;
    FOR r IN SELECT * FROM mes6a1_roles LOOP
        RAISE NOTICE 'ROLE|%|% (% codes)|samples page %|disputes page %|record / open %|resolve %|batch panel samples % disputes %|expense page %|reverse %|fee %|V16 edit %|lab supplier edit %',
            r.who, r.role, r.codes, r.samples_page, r.disputes_page, r.can_record, r.can_resolve, r.panel_samples, r.panel_disputes,
            r.expense_page, r.can_reverse, COALESCE(r.fee, 'no row'), r.v16_edit, r.lab_supplier_edit;
    END LOOP;

    -- ══ 在册的东西一个字都没动 ══
    IF md5(concat_ws('#',
        (SELECT md5(string_agg(to_jsonb(x)::text, '|' ORDER BY x.id)) FROM inbound_batches x WHERE x.created_at < v_t0),
        (SELECT md5(string_agg(to_jsonb(x)::text, '|' ORDER BY x.id)) FROM output_batches x WHERE x.created_at < v_t0),
        (SELECT md5(string_agg(to_jsonb(x)::text, '|' ORDER BY x.inbound_batch_id, x.metal)) FROM inbound_batch_metals x WHERE x.created_at < v_t0),
        (SELECT md5(string_agg(to_jsonb(x)::text, '|' ORDER BY x.output_batch_id, x.metal)) FROM output_batch_metals x WHERE x.created_at < v_t0),
        (SELECT md5(string_agg(to_jsonb(x)::text, '|' ORDER BY x.id)) FROM assay_results x WHERE x.created_at < v_t0),
        (SELECT md5(string_agg(to_jsonb(x)::text, '|' ORDER BY x.id)) FROM receipt_price_requests x WHERE x.created_at < v_t0),
        (SELECT md5(string_agg(to_jsonb(x)::text, '|' ORDER BY x.id)) FROM contracts x WHERE x.created_at < v_t0),
        (SELECT md5(string_agg(to_jsonb(x)::text, '|' ORDER BY x.id)) FROM contract_settlement_terms x WHERE x.created_at < v_t0),
        (SELECT md5(string_agg(to_jsonb(x)::text, '|' ORDER BY x.id)) FROM sales_orders x WHERE x.created_at < v_t0),
        (SELECT md5(string_agg(to_jsonb(x)::text, '|' ORDER BY x.id)) FROM expenses x WHERE x.created_at < v_t0),
        (SELECT md5(string_agg(to_jsonb(x)::text, '|' ORDER BY x.id)) FROM payments x WHERE x.created_at < v_t0),
        (SELECT md5(string_agg(to_jsonb(x)::text, '|' ORDER BY x.id)) FROM journal_entries x WHERE x.created_at < v_t0),
        (SELECT md5(string_agg(to_jsonb(x)::text, '|' ORDER BY x.id)) FROM journal_lines x WHERE x.created_at < v_t0),
        (SELECT md5(string_agg(to_jsonb(x)::text, '|' ORDER BY x.code)) FROM laboratories x WHERE x.code NOT LIKE 'ZZ-PROBE-MES6A1-%'),
        (SELECT md5(string_agg(to_jsonb(x)::text, '|' ORDER BY x.id)) FROM suppliers x WHERE x.created_at < v_t0),
        (SELECT md5(string_agg(to_jsonb(x)::text, '|' ORDER BY x.id)) FROM fx_rates x WHERE x.created_at < v_t0),
        (SELECT md5(string_agg(to_jsonb(x)::text, '|' ORDER BY x.id)) FROM metal_prices x WHERE x.created_at < v_t0),
        (SELECT md5(to_jsonb(x)::text) FROM finance_settings x),
        (SELECT md5(to_jsonb(x)::text) FROM quality_settings x))) IS DISTINCT FROM v_fp_before THEN
        RAISE EXCEPTION 'MES6A1_LIVE|a pre-existing batch, content, assay, price request, contract, settlement term, sales order, expense, payment, journal, laboratory, supplier, rate, quote, finance setting or V16 changed';
    END IF;
    IF (SELECT COALESCE(string_agg(subject_type || ':' || code, ',' ORDER BY code), '') FROM approval_pending_documents()) <> v_pending THEN
        RAISE EXCEPTION 'MES6A1_LIVE|pending documents changed: % → %', v_pending,
            (SELECT COALESCE(string_agg(subject_type || ':' || code, ',' ORDER BY code), '') FROM approval_pending_documents());
    END IF;
    IF (SELECT require_calibrated_since FROM ingest_settings) IS NOT NULL THEN RAISE EXCEPTION 'MES6A1_LIVE|require_calibrated_since set'; END IF;
    IF NOT approvals_enabled() THEN RAISE EXCEPTION 'MES6A1_LIVE|approvals switched off'; END IF;
    v_rec := pg_temp.agree_('end');
    RAISE NOTICE 'STEP|untouched|pre-existing batches, content, assays, price requests, contracts, terms, sales orders, expenses, payments, journals, laboratories, suppliers, rates, quotes, finance settings and V16 identical; pending %; approvals on; reconciliation %',
        v_pending, v_rec;
    RAISE NOTICE 'STEP|done|%', clock_timestamp() - v_t0;
END
$live$;

ROLLBACK;

SELECT 'AFTER|samples=' || (SELECT count(*) FROM samples) || '|disputes=' || (SELECT count(*) FROM assay_disputes)
    || '|probe suppliers=' || (SELECT count(*) FROM suppliers WHERE code LIKE 'ZZ-PROBE-MES6A1%')
    || '|probe labs=' || (SELECT count(*) FROM laboratories WHERE code LIKE 'ZZ-PROBE-MES6A1%')
    || '|labs linked to a supplier=' || (SELECT count(*) FROM laboratories WHERE supplier_id IS NOT NULL)
    || '|V14 set=' || (SELECT count(*) FROM contract_settlement_terms WHERE arbitration_fee_rule IS NOT NULL)
    || '|V16=' || COALESCE((SELECT internal_retention_days::text FROM quality_settings), 'NULL')
    || '|reversal reasons=' || (SELECT count(*) FROM expenses WHERE reversal_reason IS NOT NULL)
    || '|require_calibrated_since=' || COALESCE((SELECT require_calibrated_since::text FROM ingest_settings), 'NULL');
